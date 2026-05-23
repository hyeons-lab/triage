use triage_test_support::vt::TerminalFixture;

#[test]
fn vt_transcript_records_text_and_control_sequences() {
    let mut fixture = TerminalFixture::default();

    fixture.feed(b"hello\r\n\x1b[31mred\x1b[0m");

    assert_eq!(fixture.plain_text(), "hello\r\nred");
    insta::assert_snapshot!("vt_transcript", fixture.events_as_lines());
}
