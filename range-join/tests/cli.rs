use std::collections::BTreeMap;
use std::process::Command;

#[test]
fn every_benchmark_method_agrees_on_inputs_and_answer() {
    for workload in ["band", "keyed", "interval", "objects", "hop", "txn"] {
        for workers in ["1", "3"] {
            let mut expected = None;
            for method in [
                "cross",
                "cross-shadow",
                "nested",
                "range1",
                "range",
                "seek",
                "back",
                "auto",
            ] {
                if method == "back" && matches!(workload, "interval" | "objects") {
                    continue;
                }
                let output = Command::new(env!("CARGO_BIN_EXE_rangejoin-toy"))
                    .args([
                        workload,
                        method,
                        "n=128",
                        "m=128",
                        "keys=8",
                        "seed=13",
                        "rounds=3",
                        "delta=4",
                        "side=lr",
                        "check=1",
                        &format!("w={workers}"),
                    ])
                    .output()
                    .unwrap();
                assert!(
                    output.status.success(),
                    "{workload}/{method}: {}",
                    String::from_utf8_lossy(&output.stderr)
                );
                let stdout = String::from_utf8(output.stdout).unwrap();
                let fields: BTreeMap<_, _> = stdout
                    .split_whitespace()
                    .skip(2)
                    .map(|field| field.split_once('=').unwrap())
                    .collect();
                assert_eq!(fields["check"], "ok", "{stdout}");
                let answer: Vec<_> = ["left_rows", "right_rows", "out", "fingerprint"]
                    .map(|field| fields[field].to_owned())
                    .into();
                if let Some(expected) = &expected {
                    assert_eq!(&answer, expected, "{stdout}");
                } else {
                    expected = Some(answer);
                }
                if workload == "txn" {
                    assert!(fields["per_txn_ms"].parse::<f64>().unwrap() > 0.0);
                    assert!(fields["update_secs"].parse::<f64>().unwrap() > 0.0);
                }
            }
        }
    }
}

#[test]
fn cli_rejects_invalid_runs_without_printing_success() {
    for args in [
        vec!["txn", "auto", "side=wrong"],
        vec!["txn", "auto", "n=2", "m=2", "gap=1", "rounds=1", "delta=2"],
        vec!["objects", "back"],
        vec!["hop", "arrange"],
        vec!["band", "auto", "n=0"],
    ] {
        let output = Command::new(env!("CARGO_BIN_EXE_rangejoin-toy"))
            .args(&args)
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(2), "{args:?}");
        assert!(output.stdout.is_empty());
        assert!(
            String::from_utf8(output.stderr)
                .unwrap()
                .starts_with("error: ")
        );
    }
}
