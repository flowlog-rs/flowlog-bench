//! Shared fact-reading / timing / printsize scaffolding for the Ascent
//! translations. Ascent itself has NO I/O: a relation is just a
//! `pub Vec<(T, ...)>` field on the generated struct. This crate owns the
//! one generic loader so per-program code is a single `load_rel` line per
//! input relation — column types are inferred from the relation declaration,
//! mirroring what Soufflé's `.input` directive does for free.
//!
//! Output contract (parsed by scripts/engines/ascent.sh):
//!   "Dataflow executed in <secs>s"   — compute-only timing, like FlowLog
//!   "<relation>\t<size>"             — one line per .printsize relation

use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::Instant;

use dashmap::DashMap;

/// String column type: globally interned u32 key. The apples-to-apples
/// choice — FlowLog runs with --str-intern (default) and the DDlog doop
/// translation uses istring. Copy+Eq+Hash+Send+Sync, so symbol programs
/// join on u32s instead of hashing full strings per index insert.
///
/// Newtype (not a u32 alias): integer fact columns already parse via the
/// u32 FromField impl; IStr columns must intern instead.
#[derive(Copy, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Debug)]
pub struct IStr(u32);

/// Hand-rolled interner: dashmap for the string->key map, boxcar (lock-free
/// append-only vec) for key->string. lasso 0.7's ThreadedRodeo is NOT safe
/// under heavy concurrent interning — racing threads compound its bucket
/// capacity doubling (lockfree.rs store_str) until alloc() fails, which our
/// 64-thread parallel fact load hits reliably on doop-sized inputs.
/// Interned strings are leaked: they live for the whole process anyway
/// (exactly lasso's static-rodeo lifetime), and a benchmark binary exits
/// right after printing sizes.
struct Interner {
    // ahash, not SipHash: doop interns millions of ~100-byte JVM signatures
    // on the hot path (load + cat() rules); hash cost there is measurable.
    map: DashMap<&'static str, u32, ahash::RandomState>,
    strs: boxcar::Vec<&'static str>,
}

fn interner() -> &'static Interner {
    static I: OnceLock<Interner> = OnceLock::new();
    I.get_or_init(|| Interner {
        map: DashMap::with_hasher(ahash::RandomState::new()),
        strs: boxcar::Vec::new(),
    })
}

/// Intern a string (rule constants like sym("java.lang.String"), cat results).
pub fn sym(s: &str) -> IStr {
    let i = interner();
    if let Some(k) = i.map.get(s) {
        return IStr(*k);
    }
    let owned: &'static str = Box::leak(s.to_owned().into_boxed_str());
    match i.map.entry(owned) {
        // Lost a race to another thread: its key wins (our leaked copy is a
        // few stray bytes, bounded by thread count per unique string).
        dashmap::mapref::entry::Entry::Occupied(e) => IStr(*e.get()),
        dashmap::mapref::entry::Entry::Vacant(v) => {
            let k = u32::try_from(i.strs.push(owned)).expect("interner key overflow");
            v.insert(k);
            IStr(k)
        }
    }
}

/// Resolve an interned key back to its string (for cat()-style concatenation).
pub fn res(k: IStr) -> &'static str {
    interner().strs[k.0 as usize]
}

// ---------------------------------------------------------------- parsing

/// One CSV field -> one relation column.
pub trait FromField: Sized {
    fn from_field(s: &str) -> Self;
}

macro_rules! impl_from_field_int {
    ($($t:ty),*) => {$(
        impl FromField for $t {
            fn from_field(s: &str) -> Self {
                s.parse().unwrap_or_else(|e| panic!("bad {} field {s:?}: {e}", stringify!($t)))
            }
        }
    )*};
}
impl_from_field_int!(i8, i16, i32, i64, u8, u16, u32, u64, usize);

impl FromField for IStr {
    fn from_field(s: &str) -> Self {
        sym(s)
    }
}

/// One CSV line -> one relation tuple. Implemented for tuples of FromField
/// columns; `load_rel` infers WHICH impl from the relation field it assigns
/// to, so call sites never spell out types.
pub trait FromRecord: Sized {
    fn from_line(line: &str, delim: char) -> Self;
}

macro_rules! impl_from_record {
    ($($col:ident),+) => {
        impl<$($col: FromField),+> FromRecord for ($($col,)+) {
            fn from_line(line: &str, delim: char) -> Self {
                let mut it = line.split(delim);
                let tuple = ($($col::from_field(
                    it.next().unwrap_or_else(|| panic!("missing field in line {line:?}"))
                ),)+);
                // Hard assert (not debug_assert): benches run --release, and
                // a wider-than-declared row means a mis-mapped input file —
                // silently truncating it would "load fine" and produce wrong
                // relation sizes with no error. Cost is one it.next() per line.
                assert!(it.next().is_none(), "extra fields in line {line:?}");
                tuple
            }
        }
    };
}
impl_from_record!(A);
impl_from_record!(A, B);
impl_from_record!(A, B, C);
impl_from_record!(A, B, C, D);
impl_from_record!(A, B, C, D, E);
impl_from_record!(A, B, C, D, E, F);
impl_from_record!(A, B, C, D, E, F, G);
impl_from_record!(A, B, C, D, E, F, G, H);
impl_from_record!(A, B, C, D, E, F, G, H, I);
impl_from_record!(A, B, C, D, E, F, G, H, I, J);

/// Load one fact file into a relation. Generic over the collection because
/// ascent! fields are `std::vec::Vec` but ascent_par! fields are
/// `boxcar::Vec`; both implement FromIterator, and assigning to the relation
/// field pins down BOTH the collection and the tuple type — call sites stay
/// type-free. Missing file = empty relation, matching Soufflé's
/// warn-and-continue behaviour on absent .input files.
///
/// Parsing is parallel on the same rayon pool the dataflow uses (sized from
/// $WORKERS by bench_init, which runs first) — FlowLog ingests with its
/// worker threads too, so this keeps the Total comparison fair. Interning
/// (IStr columns) is safe here: the harness interner is concurrent.
pub fn load_rel<C, T>(dir: &Path, file: &str, delim: char) -> C
where
    T: FromRecord + Send,
    C: FromIterator<T> + Default,
{
    use rayon::prelude::*;

    let path = dir.join(file);
    // Scope the raw file bytes so they drop before the Vec<T> -> C move:
    // par_lines parses straight off the mmap-sized String (no Vec<&str> of
    // per-line slices — that intermediate alone is ~2x the file size on the
    // big graph datasets and would land in our measured peak RSS).
    let parsed: Vec<T> = {
        let data = match std::fs::read_to_string(&path) {
            Ok(d) => d,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                eprintln!("warning: {} not found, relation left empty", path.display());
                return C::default();
            }
            Err(e) => panic!("cannot read {}: {e}", path.display()),
        };
        data.par_lines()
            .filter(|l| !l.is_empty())
            .map(|l| T::from_line(l, delim))
            .collect()
    };
    parsed.into_iter().collect()
}

// ------------------------------------------------------------- run scaffold

/// Fact dir from argv[1]; rayon global pool from $WORKERS (same knob every
/// engine in cross_engine.sh gets).
pub fn bench_init() -> PathBuf {
    if let Ok(w) = std::env::var("WORKERS") {
        let n: usize = w.parse().expect("WORKERS must be an integer");
        rayon::ThreadPoolBuilder::new()
            .num_threads(n)
            .build_global()
            .expect("rayon pool already initialized");
    }
    PathBuf::from(
        std::env::args()
            .nth(1)
            .expect("usage: <prog> <fact_dir>   (WORKERS env sets threads)"),
    )
}

// Load seconds stashed by timed_load so timed_run can fold them into the
// total. f64 bits in an AtomicU64 (no once-cell dep needed).
static LOAD_SECS_BITS: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// Time the fact-loading phase. Loading is OUR code (Ascent has no I/O).
/// The log lines deliberately mirror FlowLog's, so scripts/lib/measure.sh
/// extracts them identically for both engines:
///   "Data loaded for ...: <secs>s"     (extract_load_seconds)
///   "Dataflow executed in <secs>s"     (extract_total_seconds, = load + run)
/// and exec = total - load falls out of the existing compute_exec_seconds.
pub fn timed_load(load: impl FnOnce()) {
    let t = Instant::now();
    load();
    let secs = t.elapsed().as_secs_f64();
    LOAD_SECS_BITS.store(secs.to_bits(), std::sync::atomic::Ordering::Relaxed);
    println!("Data loaded for all inputs: {:.6}s", secs);
}

/// Time `run()` and emit the total line ascent.sh parses. Matches FlowLog's
/// semantics: "Dataflow executed" = load + compute (see timed_load).
pub fn timed_run(run: impl FnOnce()) {
    let t = Instant::now();
    run();
    let load = f64::from_bits(LOAD_SECS_BITS.load(std::sync::atomic::Ordering::Relaxed));
    println!(
        "Dataflow executed in {:.6}s",
        t.elapsed().as_secs_f64() + load
    );
}

/// One `.printsize` line; relation name lowercased to match the
/// souffle/compiler size-crosscheck convention.
pub fn printsize(rel: &str, len: usize) {
    println!("{}\t{}", rel.to_lowercase(), len);
}
