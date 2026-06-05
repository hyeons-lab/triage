use crate::generated::triage::generated as fb;
use crate::session::{
    AttachSessionResponse, CompletedSession, InputLeaseHolder, InputLeaseState, LeaseChange,
    SessionContext, SessionSize, SessionSnapshot, StyledRow, StyledRowsResponse, StyledSpan,
    TerminalColor, TerminalCursor, TerminalStyle,
};
use flatbuffers::FlatBufferBuilder;

impl From<&SessionSize> for fb::SessionSize {
    fn from(s: &SessionSize) -> Self {
        fb::SessionSize::new(
            s.rows as u32,
            s.cols as u32,
            s.pixel_width as u32,
            s.pixel_height as u32,
            s.dpi as u32,
        )
    }
}

impl From<&TerminalCursor> for fb::TerminalCursor {
    fn from(c: &TerminalCursor) -> Self {
        fb::TerminalCursor::new(c.row as u32, c.col as u32, c.visible)
    }
}

impl From<TerminalColor> for fb::TerminalColor {
    fn from(c: TerminalColor) -> Self {
        fb::TerminalColor::new(c.red, c.green, c.blue)
    }
}

impl From<&TerminalStyle> for fb::TerminalStyle {
    fn from(s: &TerminalStyle) -> Self {
        let has_fg = s.foreground.is_some();
        let fg = s
            .foreground
            .map(fb::TerminalColor::from)
            .unwrap_or_else(|| fb::TerminalColor::new(0, 0, 0));
        let has_bg = s.background.is_some();
        let bg = s
            .background
            .map(fb::TerminalColor::from)
            .unwrap_or_else(|| fb::TerminalColor::new(0, 0, 0));
        fb::TerminalStyle::new(
            &fg,
            has_fg,
            &bg,
            has_bg,
            s.bold,
            s.dim,
            s.italic,
            s.underline,
            s.reverse,
        )
    }
}

pub fn build_styled_span<'a>(
    builder: &mut FlatBufferBuilder<'a>,
    span: &StyledSpan,
) -> flatbuffers::WIPOffset<fb::StyledSpan<'a>> {
    let text = builder.create_string(&span.text);
    let style = fb::TerminalStyle::from(&span.style);
    fb::StyledSpan::create(
        builder,
        &fb::StyledSpanArgs {
            text: Some(text),
            style: Some(&style),
        },
    )
}

pub fn build_styled_row<'a>(
    builder: &mut FlatBufferBuilder<'a>,
    row: &StyledRow,
) -> flatbuffers::WIPOffset<fb::StyledRow<'a>> {
    let mut spans = Vec::new();
    for span in &row.spans {
        spans.push(build_styled_span(builder, span));
    }
    let spans_vec = builder.create_vector(&spans);
    fb::StyledRow::create(
        builder,
        &fb::StyledRowArgs {
            spans: Some(spans_vec),
        },
    )
}

pub fn build_session_context<'a>(
    builder: &mut FlatBufferBuilder<'a>,
    ctx: &SessionContext,
) -> flatbuffers::WIPOffset<fb::SessionContext<'a>> {
    let repo = ctx
        .repository_root
        .as_ref()
        .map(|p| builder.create_string(&p.to_string_lossy()));
    let wt = ctx
        .worktree_root
        .as_ref()
        .map(|p| builder.create_string(&p.to_string_lossy()));
    let branch = ctx.branch.as_ref().map(|b| builder.create_string(b));
    fb::SessionContext::create(
        builder,
        &fb::SessionContextArgs {
            repository_root: repo,
            worktree_root: wt,
            branch,
        },
    )
}

pub fn build_session_snapshot<'a>(
    builder: &mut FlatBufferBuilder<'a>,
    snap: &SessionSnapshot,
) -> flatbuffers::WIPOffset<fb::SessionSnapshot<'a>> {
    let size = fb::SessionSize::from(&snap.size);
    let mut visible = Vec::new();
    for r in &snap.visible_rows {
        visible.push(builder.create_string(r));
    }
    let visible_vec = builder.create_vector(&visible);

    let mut styled = Vec::new();
    for r in &snap.styled_rows {
        styled.push(build_styled_row(builder, r));
    }
    let styled_vec = builder.create_vector(&styled);

    let cursor = fb::TerminalCursor::from(&snap.cursor);
    let cwd = snap
        .current_working_directory
        .as_ref()
        .map(|p| builder.create_string(&p.to_string_lossy()));
    let context = snap
        .context
        .as_ref()
        .map(|c| build_session_context(builder, c));
    let raw_output = (!snap.raw_output.is_empty()).then(|| builder.create_vector(&snap.raw_output));

    fb::SessionSnapshot::create(
        builder,
        &fb::SessionSnapshotArgs {
            output_seq: snap.output_seq,
            bytes_logged: snap.bytes_logged,
            size: Some(&size),
            visible_rows: Some(visible_vec),
            styled_rows_start: snap.styled_rows_start as u32,
            styled_rows: Some(styled_vec),
            cursor: Some(&cursor),
            current_working_directory: cwd,
            context,
            bracketed_paste_enabled: snap.bracketed_paste_enabled,
            exited: snap.exited,
            raw_output,
            raw_output_start: snap.raw_output_start,
        },
    )
}

pub fn build_completed_session<'a>(
    builder: &mut FlatBufferBuilder<'a>,
    comp: &CompletedSession,
) -> flatbuffers::WIPOffset<fb::CompletedSession<'a>> {
    let mut rows = Vec::new();
    for r in &comp.visible_rows {
        rows.push(builder.create_string(r));
    }
    let rows_vec = builder.create_vector(&rows);
    fb::CompletedSession::create(
        builder,
        &fb::CompletedSessionArgs {
            output_seq: comp.output_seq,
            bytes_logged: comp.bytes_logged,
            visible_rows: Some(rows_vec),
        },
    )
}

pub fn build_input_lease_holder<'a>(
    builder: &mut FlatBufferBuilder<'a>,
    holder: &InputLeaseHolder,
) -> flatbuffers::WIPOffset<fb::InputLeaseHolder<'a>> {
    let cid = builder.create_string(holder.client_id.as_str());
    let kind = match holder.kind {
        crate::session::InputControllerKind::Interactive => fb::InputControllerKind::Interactive,
        crate::session::InputControllerKind::Agent => fb::InputControllerKind::Agent,
    };
    fb::InputLeaseHolder::create(
        builder,
        &fb::InputLeaseHolderArgs {
            client_id: Some(cid),
            kind,
        },
    )
}

pub fn build_input_lease_state<'a>(
    builder: &mut FlatBufferBuilder<'a>,
    state: &InputLeaseState,
) -> flatbuffers::WIPOffset<fb::InputLeaseState<'a>> {
    let holder = state
        .holder
        .as_ref()
        .map(|h| build_input_lease_holder(builder, h));
    fb::InputLeaseState::create(
        builder,
        &fb::InputLeaseStateArgs {
            holder,
            generation: state.generation,
        },
    )
}

pub fn build_lease_change<'a>(
    builder: &mut FlatBufferBuilder<'a>,
    change: &LeaseChange,
) -> flatbuffers::WIPOffset<fb::LeaseChange<'a>> {
    let prev = change
        .previous
        .as_ref()
        .map(|h| build_input_lease_holder(builder, h));
    let cur = change
        .current
        .as_ref()
        .map(|h| build_input_lease_holder(builder, h));
    let action = match change.action {
        crate::session::LeaseChangeAction::Acquired => fb::LeaseChangeAction::Acquired,
        crate::session::LeaseChangeAction::Released => fb::LeaseChangeAction::Released,
        crate::session::LeaseChangeAction::TakenOver => fb::LeaseChangeAction::TakenOver,
    };
    fb::LeaseChange::create(
        builder,
        &fb::LeaseChangeArgs {
            generation: change.generation,
            previous: prev,
            current: cur,
            action,
        },
    )
}

pub fn build_attach_session_response<'a>(
    builder: &mut FlatBufferBuilder<'a>,
    res: &AttachSessionResponse,
) -> flatbuffers::WIPOffset<fb::AttachSessionResponse<'a>> {
    let snap = build_session_snapshot(builder, &res.snapshot);
    let lease = build_input_lease_state(builder, &res.lease);
    fb::AttachSessionResponse::create(
        builder,
        &fb::AttachSessionResponseArgs {
            snapshot: Some(snap),
            lease: Some(lease),
        },
    )
}

pub fn build_styled_rows_response<'a>(
    builder: &mut FlatBufferBuilder<'a>,
    res: &StyledRowsResponse,
) -> flatbuffers::WIPOffset<fb::StyledRowsResponse<'a>> {
    let mut rows = Vec::new();
    for r in &res.rows {
        rows.push(build_styled_row(builder, r));
    }
    let rows_vec = builder.create_vector(&rows);
    fb::StyledRowsResponse::create(
        builder,
        &fb::StyledRowsResponseArgs {
            output_seq: res.output_seq,
            start: res.start as u32,
            rows: Some(rows_vec),
        },
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::{SessionSize, TerminalCursor};

    fn sample(raw_output: Vec<u8>, raw_output_start: u64) -> SessionSnapshot {
        SessionSnapshot {
            output_seq: 7,
            bytes_logged: 100,
            size: SessionSize::default(),
            visible_rows: Vec::new(),
            styled_rows_start: 0,
            styled_rows: Vec::new(),
            cursor: TerminalCursor {
                row: 0,
                col: 0,
                visible: true,
            },
            current_working_directory: None,
            context: None,
            bracketed_paste_enabled: false,
            exited: false,
            raw_output,
            raw_output_start,
        }
    }

    #[test]
    fn session_snapshot_round_trips_raw_output() {
        let mut builder = FlatBufferBuilder::new();
        let off = build_session_snapshot(&mut builder, &sample(vec![1, 2, 3, 0xff], 96));
        builder.finish(off, None);
        let snap = flatbuffers::root::<fb::SessionSnapshot>(builder.finished_data()).unwrap();
        assert_eq!(snap.raw_output_start(), 96);
        assert_eq!(snap.raw_output().unwrap().bytes(), &[1, 2, 3, 0xff]);
    }

    #[test]
    fn empty_raw_output_is_omitted_for_old_client_compat() {
        let mut builder = FlatBufferBuilder::new();
        let off = build_session_snapshot(&mut builder, &sample(Vec::new(), 0));
        builder.finish(off, None);
        let snap = flatbuffers::root::<fb::SessionSnapshot>(builder.finished_data()).unwrap();
        // Append-only field absent when empty: old clients see a missing vector.
        assert!(snap.raw_output().is_none());
        assert_eq!(snap.raw_output_start(), 0);
    }
}
