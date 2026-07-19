//! Plan 25 Wave A — Pi-to-Pi envelope forwarding via the relay.
//!
//! Pi-A sends a control frame:
//!
//! ```jsonc
//! { "type": "pi_envelope", "to_pc": "<Pi-B-pubkey-b64>", "envelope": { ... } }
//! ```
//!
//! The relay authenticates Pi-A via the existing challenge-response (so we
//! already trust `sender_peer_id` here), looks up the `mesh_versions` blob
//! that lists Pi-A and confirms Pi-B is in the same Owner's member list, then
//! forwards to Pi-B (any live conn) as:
//!
//! ```jsonc
//! { "type": "pi_envelope_in", "from_pc": "<Pi-A-pubkey>", "envelope": <verbatim> }
//! ```
//!
//! Failures don't use a custom error frame — the relay synthesizes an envelope
//! with `body.type = "transport_error"` (per the plan's ACK protocol section),
//! correlated to the sender's original envelope via `re: <original_id>`.

use std::collections::{HashMap, HashSet};
use std::sync::{
    Mutex,
    atomic::{AtomicU64, Ordering},
};
use std::time::{Duration, Instant};

use axum::extract::ws::Message;
use rand::thread_rng;
use tracing::warn;

use crate::identity::canonical_ed25519_public_key;
use crate::mesh::{MeshStore, types::MeshHeader};
use crate::peers::registry::PeerRegistry;

/// Time-to-live for a positive membership lookup. The plan calls for 60 s.
/// Negative lookups are NOT cached (so adding a Pi to a mesh blob takes
/// effect immediately for subsequent forwards).
const MAX_CACHE_TTL: Duration = Duration::from_secs(60);

/// In-memory cache that maps `Pi-pubkey → set of mesh siblings`. Built lazily
/// by scanning the SQLite `mesh_versions` blobs.
#[derive(Debug)]
pub struct MeshAuthCache {
    inner: Mutex<HashMap<String, CachedMembers>>,
    refresh_snapshot_lock: Mutex<()>,
    ttl: Duration,
    next_refresh_generation: AtomicU64,
}

#[derive(Clone, Copy, Debug)]
struct RefreshAttempt {
    generation: u64,
    started_at: Instant,
}

#[derive(Debug)]
struct CachedMembers {
    members: HashSet<String>,
    cached_at: Instant,
    generation: u64,
}

impl MeshAuthCache {
    pub fn new() -> Self {
        Self::with_ttl(MAX_CACHE_TTL)
    }

    pub fn with_ttl(ttl: Duration) -> Self {
        Self {
            inner: Mutex::new(HashMap::new()),
            refresh_snapshot_lock: Mutex::new(()),
            ttl: ttl.min(MAX_CACHE_TTL),
            next_refresh_generation: AtomicU64::new(0),
        }
    }

    fn begin_refresh(&self) -> RefreshAttempt {
        RefreshAttempt {
            generation: self.next_refresh_generation.fetch_add(1, Ordering::Relaxed),
            started_at: Instant::now(),
        }
    }

    fn commit_positive_refresh(
        &self,
        pi_pk: &str,
        members: HashSet<String>,
        refresh: RefreshAttempt,
    ) -> Option<HashSet<String>> {
        let mut guard = self.inner.lock().unwrap();
        if let Some(current) = guard.get(pi_pk)
            && current.generation > refresh.generation
        {
            return (current.cached_at.elapsed() < self.ttl).then(|| current.members.clone());
        }
        if !self.ttl.is_zero() && refresh.started_at.elapsed() >= self.ttl {
            return None;
        }
        guard.insert(
            pi_pk.to_string(),
            CachedMembers {
                members: members.clone(),
                cached_at: refresh.started_at,
                generation: refresh.generation,
            },
        );
        Some(members)
    }

    /// Returns the set of mesh siblings of `pi_pk` (including `pi_pk` itself),
    /// or `None` if no Owner blob lists this Pi. A fresh cached union is reused
    /// only when it contains `target`; otherwise the store is rescanned.
    fn members_of(&self, pi_pk: &str, target: &str, store: &MeshStore) -> Option<HashSet<String>> {
        {
            let g = self.inner.lock().unwrap();
            if let Some(c) = g.get(pi_pk)
                && c.cached_at.elapsed() < self.ttl
                && c.members.contains(target)
            {
                return Some(c.members.clone());
            }
        }

        // Serialize generation assignment with the SQLite snapshot. Parsing and
        // commit happen after this lock is released, so a newer snapshot may
        // finish first, but its higher generation then wins at commit.
        let (refresh, blobs) = {
            let _snapshot_guard = self.refresh_snapshot_lock.lock().unwrap();
            {
                let guard = self.inner.lock().unwrap();
                if let Some(cached) = guard.get(pi_pk)
                    && cached.cached_at.elapsed() < self.ttl
                    && cached.members.contains(target)
                {
                    return Some(cached.members.clone());
                }
            }
            let refresh = self.begin_refresh();
            let blobs = match store.all_blobs() {
                Ok(blobs) => blobs,
                Err(error) => {
                    warn!("mesh store read failed during auth: {error}");
                    return None;
                }
            };
            (refresh, blobs)
        };

        let union = direct_members_from_blobs(pi_pk, &blobs)?;
        self.commit_positive_refresh(pi_pk, union, refresh)
    }

    /// `true` iff both Pis belong to the same direct Owner membership.
    pub fn is_authorized(&self, pi_a: &str, pi_b: &str, store: &MeshStore) -> bool {
        let (Ok(a), Ok(b)) = (
            canonical_ed25519_public_key(pi_a),
            canonical_ed25519_public_key(pi_b),
        ) else {
            return false;
        };
        self.is_authorized_canonical(&a, &b, store)
    }

    fn is_authorized_canonical(&self, pi_a: &str, pi_b: &str, store: &MeshStore) -> bool {
        match self.members_of(pi_a, pi_b, store) {
            Some(members) => members.contains(pi_b),
            None => false,
        }
    }
}

impl Default for MeshAuthCache {
    fn default() -> Self {
        Self::new()
    }
}

fn direct_members_from_blobs(pi_pk: &str, blobs: &[Vec<u8>]) -> Option<HashSet<String>> {
    let mut union = HashSet::new();
    for blob in blobs {
        let header: MeshHeader = match serde_json::from_slice(blob) {
            Ok(header) => header,
            Err(_) => continue,
        };
        let owner_members: Result<HashSet<String>, _> = header
            .members
            .iter()
            .map(|member| canonical_ed25519_public_key(&member.remote_epk))
            .collect();
        let Ok(owner_members) = owner_members else {
            continue;
        };
        if owner_members.contains(pi_pk) {
            union.extend(owner_members);
        }
    }
    (!union.is_empty()).then_some(union)
}

/// What the routing loop should do after calling `handle_pi_envelope`.
pub enum PiForwardResult {
    /// Envelope delivered (or accepted by the channel of) Pi-B.
    Forwarded,
    /// Send this message back to the original sender via their own WS sink.
    /// Always a `pi_envelope_in` whose envelope carries
    /// `body.type = "transport_error"`.
    TransportError(Message),
}

#[derive(Clone, Copy)]
enum TransportErrorReason {
    Offline,
    NotAuthorized,
    BadEnvelope,
}

impl TransportErrorReason {
    fn as_str(self) -> &'static str {
        match self {
            Self::Offline => "offline",
            Self::NotAuthorized => "not_authorized",
            Self::BadEnvelope => "bad_envelope",
        }
    }
}

/// Handles one `pi_envelope` frame. `sender_peer_id` is the authenticated
/// Pi-A pubkey (already verified by the WS handshake).
pub async fn handle_pi_envelope(
    sender_peer_id: &str,
    frame: &serde_json::Value,
    registry: &PeerRegistry,
    mesh: &MeshStore,
    cache: &MeshAuthCache,
) -> PiForwardResult {
    let to_pc = frame.get("to_pc").and_then(|v| v.as_str());
    let envelope = frame.get("envelope");

    let (to_pc, envelope) = match (to_pc, envelope) {
        (Some(t), Some(e)) if e.is_object() && !t.is_empty() => (t, e),
        _ => {
            return PiForwardResult::TransportError(make_transport_error(
                frame.get("envelope"),
                TransportErrorReason::BadEnvelope,
            ));
        }
    };

    let sender = match canonical_ed25519_public_key(sender_peer_id) {
        Ok(value) => value,
        Err(_) => {
            return PiForwardResult::TransportError(make_transport_error(
                frame.get("envelope"),
                TransportErrorReason::BadEnvelope,
            ));
        }
    };
    let target = match canonical_ed25519_public_key(to_pc) {
        Ok(value) => value,
        Err(_) => {
            return PiForwardResult::TransportError(make_transport_error(
                Some(envelope),
                TransportErrorReason::BadEnvelope,
            ));
        }
    };

    if !cache.is_authorized_canonical(&sender, &target, mesh) {
        return PiForwardResult::TransportError(make_transport_error(
            Some(envelope),
            TransportErrorReason::NotAuthorized,
        ));
    }

    let outbound = serde_json::json!({
        "type": "pi_envelope_in",
        "from_pc": sender,
        "envelope": envelope, // verbatim
    });
    let msg = Message::Text(outbound.to_string());

    if registry.forward_to_peer(&target, msg) {
        PiForwardResult::Forwarded
    } else {
        PiForwardResult::TransportError(make_transport_error(
            Some(envelope),
            TransportErrorReason::Offline,
        ))
    }
}

fn is_uuid(value: &str) -> bool {
    value.len() == 36
        && value.as_bytes().iter().enumerate().all(|(index, byte)| {
            if matches!(index, 8 | 13 | 18 | 23) {
                *byte == b'-'
            } else {
                byte.is_ascii_hexdigit()
            }
        })
}

fn new_uuid_v4() -> String {
    use rand::RngCore;

    let mut bytes = [0_u8; 16];
    thread_rng().fill_bytes(&mut bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        bytes[0],
        bytes[1],
        bytes[2],
        bytes[3],
        bytes[4],
        bytes[5],
        bytes[6],
        bytes[7],
        bytes[8],
        bytes[9],
        bytes[10],
        bytes[11],
        bytes[12],
        bytes[13],
        bytes[14],
        bytes[15],
    )
}

/// Builds a `pi_envelope_in` frame whose inner envelope carries
/// `body.type = "transport_error"`, correlated to the original via `re`.
fn make_transport_error(
    envelope: Option<&serde_json::Value>,
    reason: TransportErrorReason,
) -> Message {
    let re = envelope
        .and_then(|value| value.get("id"))
        .and_then(serde_json::Value::as_str)
        .filter(|value| is_uuid(value))
        .map(str::to_owned);
    let to_addr = envelope
        .and_then(|value| value.get("from"))
        .and_then(serde_json::Value::as_str)
        .filter(|address| !address.is_empty())
        .unwrap_or("_unknown");

    let err_envelope = serde_json::json!({
        "from": "_relay",
        "to": to_addr,
        "id": new_uuid_v4(),
        "re": re,
        "body": { "type": "transport_error", "reason": reason.as_str() },
    });

    let frame = serde_json::json!({
        "type": "pi_envelope_in",
        "from_pc": "_relay",
        "envelope": err_envelope,
    });
    Message::Text(frame.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::PresenceManager;
    use crate::RoomManager;
    use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
    use std::sync::Arc;

    fn fresh_cache_and_store() -> (MeshAuthCache, MeshStore) {
        (MeshAuthCache::new(), MeshStore::open_in_memory().unwrap())
    }

    fn pi_key(byte: u8) -> String {
        use base64::{Engine as _, engine::general_purpose::STANDARD};
        STANDARD.encode([byte; 32])
    }

    fn pi_key_url_safe(byte: u8) -> String {
        URL_SAFE_NO_PAD.encode([byte; 32])
    }

    fn owner_blob(owner_pk: &[u8], members: &[&str], version: u64) -> Vec<u8> {
        let pk_b64 = {
            use base64::{Engine as _, engine::general_purpose::STANDARD as B64};
            B64.encode(owner_pk)
        };
        let members_json: Vec<serde_json::Value> = members
            .iter()
            .map(|member| {
                serde_json::json!({
                    "remote_epk": member,
                    "relay_url": "wss://relay.example.test",
                    "paired_at": "2025-01-01T00:00:00.000Z",
                })
            })
            .collect();
        serde_json::to_vec(&serde_json::json!({
            "owner_pk": pk_b64,
            "version": version,
            "issued_at": 1_700_000_000_000_u64,
            "members": members_json,
        }))
        .unwrap()
    }

    fn write_owner_blob(store: &MeshStore, owner_pk: &[u8], members: &[&str], version: u64) {
        use sha2::{Digest, Sha256};
        let blob_bytes = owner_blob(owner_pk, members, version);
        let hash = {
            let d = Sha256::digest(owner_pk);
            let mut s = String::with_capacity(64);
            for b in d {
                s.push_str(&format!("{b:02x}"));
            }
            s
        };
        store
            .upsert(&hash, owner_pk, version, &blob_bytes, &[0u8; 64], 0)
            .unwrap();
    }

    #[test]
    fn multi_owner_union_ignores_sender_only_owner_inserted_first() {
        let pi_a = pi_key(0x0a);
        let pi_b = pi_key(0x0b);
        let blobs = vec![
            owner_blob(&[1; 32], &[&pi_a], 1),
            owner_blob(&[2; 32], &[&pi_a, &pi_b], 1),
        ];

        assert_eq!(
            direct_members_from_blobs(&pi_a, &blobs),
            Some(HashSet::from([pi_a, pi_b])),
        );
    }

    #[test]
    fn multi_owner_union_is_order_independent_and_symmetric() {
        let pi_a = pi_key(0x0a);
        let pi_b = pi_key(0x0b);
        let pi_c = pi_key(0x0c);
        let owner_ab = owner_blob(&[1; 32], &[&pi_a, &pi_b], 1);
        let owner_ac = owner_blob(&[2; 32], &[&pi_a, &pi_c], 1);
        let forward = vec![owner_ab.clone(), owner_ac.clone()];
        let reverse = vec![owner_ac, owner_ab];

        let forward_a = direct_members_from_blobs(&pi_a, &forward).unwrap();
        let reverse_a = direct_members_from_blobs(&pi_a, &reverse).unwrap();
        assert_eq!(forward_a, reverse_a);
        assert_eq!(
            forward_a,
            HashSet::from([pi_a.clone(), pi_b.clone(), pi_c.clone()]),
        );

        for blobs in [&forward, &reverse] {
            let members_a = direct_members_from_blobs(&pi_a, blobs).unwrap();
            let members_b = direct_members_from_blobs(&pi_b, blobs).unwrap();
            let members_c = direct_members_from_blobs(&pi_c, blobs).unwrap();
            assert!(members_a.contains(&pi_b) && members_b.contains(&pi_a));
            assert!(members_a.contains(&pi_c) && members_c.contains(&pi_a));
            assert!(!members_b.contains(&pi_c) && !members_c.contains(&pi_b));
        }
    }

    #[test]
    fn authorization_is_direct_not_transitive() {
        let (cache, store) = fresh_cache_and_store();
        let a = pi_key(0x0a);
        let b = pi_key(0x0b);
        let c = pi_key(0x0c);
        write_owner_blob(&store, &[1; 32], &[&a, &b], 1);
        write_owner_blob(&store, &[2; 32], &[&b, &c], 1);

        assert!(cache.is_authorized(&a, &b, &store));
        assert!(cache.is_authorized(&b, &a, &store));
        assert!(cache.is_authorized(&b, &c, &store));
        assert!(cache.is_authorized(&c, &b, &store));
        assert!(!cache.is_authorized(&a, &c, &store));
        assert!(!cache.is_authorized(&c, &a, &store));
    }

    #[test]
    fn canonical_variants_share_positive_cache_state() {
        let (cache, store) = fresh_cache_and_store();
        let a = pi_key(0xfb);
        let b = pi_key(0xef);
        let a_url_safe = pi_key_url_safe(0xfb);
        let b_url_safe = pi_key_url_safe(0xef);
        let owner = [3_u8; 32];
        write_owner_blob(&store, &owner, &[&a_url_safe, &b_url_safe], 1);

        assert!(cache.is_authorized(&a_url_safe, &b_url_safe, &store));
        write_owner_blob(&store, &owner, &[&a_url_safe], 2);

        assert!(cache.is_authorized(&a, &b, &store));
    }

    #[test]
    fn zero_ttl_observes_membership_revocation_on_next_lookup() {
        let cache = MeshAuthCache::with_ttl(Duration::ZERO);
        let store = MeshStore::open_in_memory().unwrap();
        let a = pi_key(0x0a);
        let b = pi_key(0x0b);
        let owner = [4_u8; 32];
        write_owner_blob(&store, &owner, &[&a, &b], 1);
        assert!(cache.is_authorized(&a, &b, &store));

        write_owner_blob(&store, &owner, &[&a], 2);
        assert!(!cache.is_authorized(&a, &b, &store));
    }

    #[test]
    fn positive_cache_survives_immediate_revoke_before_expiry() {
        let cache = MeshAuthCache::with_ttl(Duration::from_secs(60));
        let store = MeshStore::open_in_memory().unwrap();
        let a = pi_key(0x0a);
        let b = pi_key(0x0b);
        let owner = [5_u8; 32];
        write_owner_blob(&store, &owner, &[&a, &b], 1);
        assert!(cache.is_authorized(&a, &b, &store));

        write_owner_blob(&store, &owner, &[&a], 2);
        assert!(cache.is_authorized(&a, &b, &store));
    }

    #[test]
    fn cached_target_miss_refreshes_after_membership_expansion() {
        let cache = MeshAuthCache::with_ttl(Duration::from_secs(60));
        let store = MeshStore::open_in_memory().unwrap();
        let a = pi_key(0x0a);
        let b = pi_key(0x0b);
        let owner = [6_u8; 32];
        write_owner_blob(&store, &owner, &[&a], 1);
        assert!(!cache.is_authorized(&a, &b, &store));

        write_owner_blob(&store, &owner, &[&a, &b], 2);
        assert!(cache.is_authorized(&a, &b, &store));
    }

    #[test]
    fn configured_ttl_is_capped_at_sixty_seconds() {
        let cache = MeshAuthCache::with_ttl(Duration::from_secs(600));
        let store = MeshStore::open_in_memory().unwrap();
        let a = pi_key(0x0a);
        let b = pi_key(0x0b);
        let refresh = RefreshAttempt {
            generation: 0,
            started_at: Instant::now()
                .checked_sub(Duration::from_secs(61))
                .expect("test instant must support a small subtraction"),
        };
        let committed =
            cache.commit_positive_refresh(&a, HashSet::from([a.clone(), b.clone()]), refresh);

        assert_eq!(committed, None);
        assert!(!cache.inner.lock().unwrap().contains_key(&a));
        assert!(!cache.is_authorized(&a, &b, &store));
    }

    #[tokio::test]
    async fn authorized_same_owner() {
        let (cache, store) = fresh_cache_and_store();
        let pi_a = pi_key(0x0a);
        let pi_b = pi_key(0x0b);
        write_owner_blob(&store, &[1u8; 32], &[&pi_a, &pi_b], 1);
        assert!(cache.is_authorized(&pi_a, &pi_b, &store));
        assert!(cache.is_authorized(&pi_b, &pi_a, &store));
    }

    #[tokio::test]
    async fn not_authorized_cross_owner() {
        let (cache, store) = fresh_cache_and_store();
        let pi_a = pi_key(0x0a);
        let pi_b = pi_key(0x0b);
        write_owner_blob(&store, &[1u8; 32], &[&pi_a], 1);
        write_owner_blob(&store, &[2u8; 32], &[&pi_b], 1);
        assert!(!cache.is_authorized(&pi_a, &pi_b, &store));
        assert!(!cache.is_authorized(&pi_b, &pi_a, &store));
    }

    #[tokio::test]
    async fn bad_envelope_when_missing_to_pc() {
        let registry = Arc::new(PeerRegistry::new(
            Arc::new(PresenceManager::new()),
            Arc::new(RoomManager::new()),
            Arc::new(crate::metrics::FirehoseMetrics::new()),
        ));
        let store = MeshStore::open_in_memory().unwrap();
        let cache = MeshAuthCache::new();
        let frame = serde_json::json!({
            "type": "pi_envelope",
            "envelope": {
                "from": "x",
                "to": "y",
                "id": "30000000-0000-4000-8000-000000000003",
                "re": null,
                "body": {},
            },
        });
        match handle_pi_envelope(&pi_key(0x0a), &frame, &registry, &store, &cache).await {
            PiForwardResult::TransportError(_) => {} // expected
            PiForwardResult::Forwarded => panic!("must be transport_error"),
        }
    }
}
