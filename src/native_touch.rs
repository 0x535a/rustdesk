pub fn send_from_flutter(session_id: &hbb_common::SessionID, value: &serde_json::Value) {
    use crate::{client::send_pointer_device_event, flutter::sessions};
    use base::{message_proto::PointerDeviceEvent, native_touch::Frame};
    use serde::Deserialize;

    let frame = match Frame::deserialize(value) {
        Ok(frame) => frame,
        Err(error) => {
            hbb_common::log::trace!("Invalid native touch bridge frame: {error}");
            return;
        }
    };
    if !frame.validate() {
        hbb_common::log::trace!("Invalid native touch contact data");
        return;
    }
    if let Some(session) = sessions::get_session_by_session_id(session_id) {
        let mut event = PointerDeviceEvent::new();
        event.set_raw_touch_frame(frame.into_proto());
        send_pointer_device_event(event, false, false, false, false, session.as_ref());
    }
}

pub fn handle_status(peer_id: &str, status: base::message_proto::RawTouchStatus) {
    use hbb_common::rendezvous_proto::ConnType;
    if let Some(session) =
        crate::flutter::sessions::get_session_by_peer_id(peer_id.to_owned(), ConnType::DEFAULT_CONN)
    {
        session.push_event(
            "native_touch_status",
            &[
                ("enabled", status.enabled.to_string()),
                ("display", status.display.to_string()),
                ("error", status.error),
            ],
            &[],
        );
    }
}
