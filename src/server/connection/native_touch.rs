use super::*;

impl Connection {
    pub(super) async fn handle_native_touch(&mut self, raw: RawTouchFrame) {
        use base::native_touch::Frame;

        let requested_display = raw.display;
        let frame = Frame::from(&raw);
        if !frame.enabled {
            self.native_touch.stop().await;
            self.send_native_touch_status(false, requested_display, String::new())
                .await;
            return;
        }
        if !self.authorized
            || !self.peer_keyboard_enabled()
            || self.view_camera
            || self.file_transfer.is_some()
            || self.terminal
            || !frame.validate()
            || requested_display as usize != self.display_idx
        {
            let was_active = self.native_touch.active();
            self.native_touch.stop().await;
            if frame.start || was_active {
                self.send_native_touch_status(
                    false,
                    requested_display,
                    "Native touch control is not permitted".into(),
                )
                .await;
            }
            return;
        }
        let display = display_service::try_get_displays().ok().and_then(|all| {
            all.get(self.display_idx)
                .and_then(|d| d.name().parse::<u32>().ok())
        });
        let Some(display) = display else {
            self.native_touch.stop().await;
            self.send_native_touch_status(
                false,
                requested_display,
                "Native touch display is unavailable".into(),
            )
            .await;
            return;
        };
        if frame.start {
            match self.native_touch.start(display).await {
                Ok(()) => {
                    self.send_native_touch_status(true, requested_display, String::new())
                        .await
                }
                Err(error) => {
                    self.send_native_touch_status(false, requested_display, error.to_string())
                        .await
                }
            }
        } else if self.native_touch.active() {
            if let Err(error) = self.native_touch.send(&frame, display).await {
                self.native_touch.stop().await;
                self.send_native_touch_status(false, requested_display, error.to_string())
                    .await;
            }
        }
    }

    async fn send_native_touch_status(&mut self, enabled: bool, display: u32, error: String) {
        let mut event = PointerDeviceEvent::new();
        event.set_raw_touch_status(RawTouchStatus {
            enabled,
            display,
            error,
            ..Default::default()
        });
        let mut message = Message::new();
        message.set_pointer_device_event(event);
        self.send(message).await;
    }

    pub(super) async fn stop_native_touch(&mut self) {
        if self.native_touch.active() {
            self.native_touch.stop().await;
            self.send_native_touch_status(false, self.display_idx as _, String::new())
                .await;
        }
    }
}
