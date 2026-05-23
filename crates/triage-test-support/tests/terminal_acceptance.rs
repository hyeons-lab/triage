use triage_test_support::terminal_acceptance::SCENARIOS;

#[test]
fn terminal_acceptance_scenarios_have_unique_names() {
    let mut names = SCENARIOS
        .iter()
        .map(|scenario| scenario.name)
        .collect::<Vec<_>>();
    names.sort_unstable();
    names.dedup();

    assert_eq!(names.len(), SCENARIOS.len());
}

#[test]
fn terminal_acceptance_scenarios_capture_expected_parser_events() {
    let snapshot = SCENARIOS
        .iter()
        .map(|scenario| {
            format!(
                "## {} ({})\n{}\n",
                scenario.name,
                scenario.capability.as_str(),
                scenario.transcript_lines()
            )
        })
        .collect::<Vec<_>>()
        .join("\n");

    insta::assert_snapshot!("terminal_acceptance_scenarios", snapshot);
}

#[test]
fn chunked_replay_matches_contiguous_stream() {
    for scenario in SCENARIOS {
        assert_eq!(
            scenario.replay_transcript_lines(),
            scenario.transcript_lines(),
            "scenario {:?} changed when split across replay chunks",
            scenario.name
        );
    }
}

#[test]
fn log_tee_scenario_preserves_raw_bytes() {
    let scenario = SCENARIOS
        .iter()
        .find(|scenario| scenario.name == "log_tee_preserves_raw_bytes")
        .expect("log tee scenario exists");

    assert_eq!(scenario.bytes, b"raw\x00bytes\x1b[31mred\x1b[0m\r\n");
}
