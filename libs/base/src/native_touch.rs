use crate::message_proto::{RawTouchContact, RawTouchFrame};
use serde_derive::{Deserialize, Serialize};

pub const MAX_CONTACTS: usize = 10;

#[derive(Debug, Deserialize, Serialize)]
pub struct Contact {
    pub id: u32,
    pub x: f64,
    pub y: f64,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct Frame {
    pub enabled: bool,
    pub display: u32,
    pub contacts: Vec<Contact>,
    #[serde(default)]
    pub start: bool,
}

impl Frame {
    pub fn validate(&self) -> bool {
        (self.enabled || self.contacts.is_empty())
            && (!self.start || (self.enabled && self.contacts.is_empty()))
            && self.contacts.len() <= MAX_CONTACTS
            && self.contacts.iter().enumerate().all(|(index, point)| {
                (1..=127).contains(&point.id)
                    && point.x.is_finite()
                    && point.y.is_finite()
                    && (0.0..=1.0).contains(&point.x)
                    && (0.0..=1.0).contains(&point.y)
                    && !self.contacts[..index].iter().any(|p| p.id == point.id)
            })
    }

    pub fn into_proto(self) -> RawTouchFrame {
        RawTouchFrame {
            enabled: self.enabled,
            display: self.display,
            start: self.start,
            contacts: self
                .contacts
                .into_iter()
                .map(|p| RawTouchContact {
                    id: p.id,
                    x: p.x,
                    y: p.y,
                    ..Default::default()
                })
                .collect(),
            ..Default::default()
        }
    }
}

impl From<&RawTouchFrame> for Frame {
    fn from(value: &RawTouchFrame) -> Self {
        Self {
            enabled: value.enabled,
            display: value.display,
            start: value.start,
            contacts: value
                .contacts
                .iter()
                .map(|p| Contact {
                    id: p.id,
                    x: p.x,
                    y: p.y,
                })
                .collect(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use protobuf::Message;

    #[test]
    fn ten_raw_contacts_survive_wire_roundtrip() {
        let input = Frame {
            enabled: true,
            display: 2,
            start: false,
            contacts: (1..=10)
                .map(|id| Contact {
                    id,
                    x: id as f64 / 10.0,
                    y: 0.5,
                })
                .collect(),
        };
        assert!(input.validate());
        let encoded = input.into_proto().write_to_bytes().unwrap();
        let output = Frame::from(&RawTouchFrame::parse_from_bytes(&encoded).unwrap());
        assert!(output.validate());
        assert_eq!(output.display, 2);
        assert_eq!(output.contacts.len(), 10);
        assert_eq!(output.contacts[9].id, 10);
        assert_eq!(output.contacts[9].x, 1.0);
    }

    #[test]
    fn rejects_invalid_contacts_and_accepts_release() {
        let mut frame = Frame {
            enabled: true,
            display: 0,
            contacts: vec![],
            start: false,
        };
        assert!(frame.validate());
        for id in 1..=11 {
            frame.contacts.push(Contact { id, x: 0.5, y: 0.5 });
        }
        assert!(!frame.validate());
        frame.contacts.truncate(2);
        frame.contacts[1].id = 1;
        assert!(!frame.validate());
        frame.contacts.truncate(1);
        frame.contacts[0].x = f64::NAN;
        assert!(!frame.validate());
        frame.contacts[0].x = 0.5;
        frame.enabled = false;
        assert!(!frame.validate());
        frame.contacts.clear();
        assert!(frame.validate());
    }
}
