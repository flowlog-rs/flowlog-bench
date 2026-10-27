use std::fmt::Display;
use std::str::FromStr;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Method {
    Arrange,
    Cross,
    CrossShadow,
    Nested,
    Range1,
    Range,
    Seek,
    Back,
    Auto,
}

impl Method {
    pub fn name(self) -> &'static str {
        match self {
            Self::Arrange => "arrange",
            Self::Cross => "cross",
            Self::CrossShadow => "cross-shadow",
            Self::Nested => "nested",
            Self::Range1 => "range1",
            Self::Range => "range",
            Self::Seek => "seek",
            Self::Back => "back",
            Self::Auto => "auto",
        }
    }

    pub fn strategy(self) -> rangejoin_toy::seek_join::Strategy {
        use rangejoin_toy::seek_join::Strategy;
        match self {
            Self::Seek => Strategy::Seek,
            Self::Back => Strategy::SeekBack,
            Self::Auto => Strategy::Auto,
            _ => unreachable!("only seek, back, and auto select a seeking strategy"),
        }
    }
}

impl FromStr for Method {
    type Err = String;

    fn from_str(text: &str) -> Result<Self, String> {
        match text {
            "arrange" => Ok(Self::Arrange),
            "cross" => Ok(Self::Cross),
            "cross-shadow" => Ok(Self::CrossShadow),
            "nested" => Ok(Self::Nested),
            "range1" => Ok(Self::Range1),
            "range" => Ok(Self::Range),
            "seek" => Ok(Self::Seek),
            "back" => Ok(Self::Back),
            "auto" => Ok(Self::Auto),
            _ => Err(format!("unknown method '{text}'")),
        }
    }
}

#[derive(Clone, Debug)]
pub struct Args {
    pub workload: String,
    pub method: Method,
    pub n: usize,
    pub m: usize,
    pub gap: i64,
    pub width: i64,
    pub keys: usize,
    pub skew: f64,
    pub rounds: usize,
    pub delta: usize,
    pub side: String,
    pub workers: usize,
    pub seed: u64,
    pub check: bool,
}

fn number<T: FromStr<Err: Display>>(name: &str, text: &str) -> Result<T, String> {
    text.parse()
        .map_err(|error| format!("invalid {name}={text}: {error}"))
}

impl Args {
    pub fn parse(argv: impl IntoIterator<Item = String>) -> Result<Self, String> {
        let mut argv = argv.into_iter();
        let workload = argv
            .next()
            .ok_or("usage: rangejoin-toy <workload> <method> [key=value ...]")?;
        let method = argv.next().ok_or("missing method")?.parse()?;
        let mut args = Self {
            workload,
            method,
            n: 10_000,
            m: 10_000,
            gap: 10,
            width: 100,
            keys: 1_000,
            skew: 1.0,
            rounds: 20,
            delta: 10,
            side: "l".into(),
            workers: 1,
            seed: 7,
            check: false,
        };
        let mut m = None;
        for option in argv {
            let (name, value) = option.split_once('=').ok_or("options must be key=value")?;
            match name {
                "n" => args.n = number(name, value)?,
                "m" => m = Some(number(name, value)?),
                "gap" => args.gap = number(name, value)?,
                "width" => args.width = number(name, value)?,
                "keys" => args.keys = number(name, value)?,
                "skew" => args.skew = number(name, value)?,
                "rounds" => args.rounds = number(name, value)?,
                "delta" => args.delta = number(name, value)?,
                "side" => args.side = value.into(),
                "workers" | "w" => args.workers = number(name, value)?,
                "seed" => args.seed = number(name, value)?,
                "check" => {
                    args.check = match value {
                        "1" | "true" => true,
                        "0" | "false" => false,
                        _ => return Err("check must be 0, 1, false, or true".into()),
                    }
                }
                _ => return Err(format!("unknown option '{name}'")),
            }
        }
        args.m = m.unwrap_or(args.n);
        args.validate()?;
        Ok(args)
    }

    fn validate(&self) -> Result<(), String> {
        if !matches!(
            self.workload.as_str(),
            "band" | "keyed" | "interval" | "objects" | "hop" | "txn"
        ) {
            return Err(format!("unknown workload '{}'", self.workload));
        }
        if self.n == 0 || self.m == 0 || self.keys == 0 || self.workers == 0 {
            return Err("n, m, keys, and workers must be positive".into());
        }
        if self.gap <= 0 || self.width <= 0 || !self.skew.is_finite() || self.skew <= 0.0 {
            return Err("gap, width, and skew must be positive and finite".into());
        }
        if !matches!(self.side.as_str(), "l" | "r" | "lr") {
            return Err("side must be l, r, or lr".into());
        }
        if matches!(self.workload.as_str(), "band" | "hop" | "objects") && self.n != self.m {
            return Err("band, objects, and hop have one input; m must equal n".into());
        }
        if matches!(self.workload.as_str(), "interval" | "objects") && self.method == Method::Back {
            return Err(format!(
                "{} does not support back: arbitrary intervals are not reverse-monotone",
                self.workload
            ));
        }
        if self.workload == "hop" && self.method == Method::Arrange {
            return Err(
                "hop does not support arrange: arrangement-only work is not recursive reachability"
                    .into(),
            );
        }
        if self.workload == "txn"
            && (self.rounds == 0
                || self.delta == 0
                || self.rounds.checked_mul(self.delta).is_none())
        {
            return Err("txn needs positive rounds and delta whose product fits usize".into());
        }
        // Bound both generated points and shadow arithmetic before allocating data.
        let max_point = (self.n.max(self.m) as u128) * (2 * self.gap as u128 - 1);
        if max_point + 2 * self.width as u128 > i64::MAX as u128 || self.keys > i64::MAX as usize {
            return Err("input sizes, gap, or width would overflow i64 data/shadow columns".into());
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::{Args, Method};

    fn parse(options: &[&str]) -> Result<Args, String> {
        Args::parse(options.iter().map(|s| s.to_string()))
    }

    #[test]
    fn defaults_and_matched_baseline() {
        let args = parse(&["keyed", "cross-shadow", "n=42"]).unwrap();
        assert_eq!((args.n, args.m), (42, 42));
        assert_eq!(args.method, Method::CrossShadow);
    }

    #[test]
    fn rejects_invalid_or_unsupported_runs_before_starting_workers() {
        for option in [
            "n=0",
            "m=0",
            "w=0",
            "keys=0",
            "gap=0",
            "gap=-1",
            "width=0",
            "skew=NaN",
            "skew=inf",
            "skew=-1",
            "check=typo",
            "side=wrong",
            "width=9223372036854775807",
            "gap=9223372036854775807",
        ] {
            assert!(parse(&["band", "auto", option]).is_err(), "{option}");
        }
        for options in [
            vec!["band", "auto", "m=20"],
            vec!["interval", "back"],
            vec!["objects", "back"],
            vec!["hop", "arrange"],
            vec!["txn", "auto", "rounds=0"],
            vec!["txn", "auto", "delta=0"],
            vec!["missing", "auto"],
            vec!["band", "missing"],
        ] {
            assert!(parse(&options).is_err(), "{options:?}");
        }
    }
}
