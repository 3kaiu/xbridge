//! Generic, business-free control-plane messages.
//!
//! Only **control** frames (subscribe / unsubscribe / ping / config) are
//! JSON-encoded text frames. The **data** plane is raw binary `Vec<u8>` with
//! zero encoding overhead — see [`crate::server`] and PRD §1.2.4.
//!
//! ## Naming: `action` vs `method`
//!
//! Control messages use the field name `action` (not `method`) **by design**.
//! The JSON-RPC bridge-call protocol uses `method` on the data plane. Using a
//! different field name on the control plane prevents a control frame from
//! being misinterpreted as a data-plane bridge call (or vice versa) when both
//! arrive as text frames on the same WebSocket connection.
//!
//! These structs are intentionally schema-light: `params` is a
//! `serde_json::Value` so any business-specific control vocabulary can be
//! layered on top by downstream crates WITHOUT `xbridge_core` knowing about
//! it. This is the "zero business coupling" invariant.

use serde::{Deserialize, Serialize};

/// A control message sent over a text frame. Recognized `action` values are
/// the responsibility of the consuming layer; this crate only parses and
/// forwards the raw struct.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ControlMessage {
    /// Action name, e.g. `"subscribe"`, `"unsubscribe"`, `"ping"`.
    pub action: String,
    /// Free-form parameters. Use `Value::Null` when none.
    #[serde(default = "default_params")]
    pub params: serde_json::Value,
}

fn default_params() -> serde_json::Value {
    serde_json::Value::Null
}

/// Reply to a control message. Always JSON-serializable.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ControlResponse {
    /// `true` when the action succeeded.
    pub ok: bool,
    /// Error reason when `ok == false`, else `None`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    /// Optional payload (e.g. an assigned subscriber id). Omitted when absent.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<serde_json::Value>,
}

impl ControlResponse {
    pub fn ok() -> Self {
        Self {
            ok: true,
            error: None,
            data: None,
        }
    }

    pub fn ok_with(data: serde_json::Value) -> Self {
        Self {
            ok: true,
            error: None,
            data: Some(data),
        }
    }

    pub fn err(msg: impl Into<String>) -> Self {
        Self {
            ok: false,
            error: Some(msg.into()),
            data: None,
        }
    }

    /// Serialize to a JSON text frame string. Cheap single-pass encode.
    pub fn to_json_string(&self) -> String {
        serde_json::to_string(self).unwrap_or_else(|_| r#"{"ok":false,"error":"encode_failed"}"#.into())
    }
}

impl ControlMessage {
    /// Parse a control message from a text frame. Returns `None` when the
    /// payload is not valid JSON or does not contain an `action` string —
    /// callers should treat that as a malformed control frame and drop it.
    pub fn parse(raw: &str) -> Option<Self> {
        serde_json::from_str::<ControlMessage>(raw).ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrips_control_message() {
        let msg = ControlMessage {
            action: "subscribe".into(),
            params: serde_json::json!({ "topic": "audio" }),
        };
        let s = serde_json::to_string(&msg).unwrap();
        let back = ControlMessage::parse(&s).unwrap();
        assert_eq!(back.action, "subscribe");
        assert_eq!(back.params["topic"], "audio");
    }

    #[test]
    fn control_response_ok_omits_error() {
        let s = ControlResponse::ok().to_json_string();
        assert!(s.contains(r#""ok":true"#));
        assert!(!s.contains("error"));
    }

    #[test]
    fn control_response_err_includes_message() {
        let s = ControlResponse::err("nope").to_json_string();
        assert!(s.contains(r#""ok":false"#));
        assert!(s.contains(r#""error":"nope""#));
    }

    #[test]
    fn parse_rejects_non_object() {
        assert!(ControlMessage::parse("not json").is_none());
        assert!(ControlMessage::parse("42").is_none());
    }

    #[test]
    fn params_defaults_to_null() {
        let s = r#"{"action":"ping"}"#;
        let m = ControlMessage::parse(s).unwrap();
        assert_eq!(m.action, "ping");
        assert!(m.params.is_null());
    }
}
