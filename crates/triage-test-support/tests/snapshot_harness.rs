use triage_test_support::snapshots::{frame, normalize_text};

#[test]
fn renderer_golden_snapshot_is_normalized() {
    let frame = frame([
        "Triage",
        "repo: hyeons-lab/triage",
        "attention: awaiting-input",
        "",
    ]);

    insta::assert_snapshot!("sample_renderer_frame", frame);
}

#[test]
fn text_normalization_is_platform_stable() {
    assert_eq!(normalize_text("one\r\ntwo\rthree\n"), "one\ntwo\nthree\n");
}

#[test]
fn frame_preserves_intentional_final_blank_rows() {
    assert_eq!(frame(["one", ""]), "one\n");
}
