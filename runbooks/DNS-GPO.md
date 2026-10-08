# DNS And Group Policy

## DNS Records

Run on the owning Windows DNS server. Supply `Zone`, relative `RecordName`, `RecordType` (`A` or `CNAME`) and, for `Upsert`, `Value`. Use only delegated application zones; `Zone` is caller input, not a security boundary.

1. Inspect the exact record and confirm zone ownership, replication topology, consumers and TTL.
2. Preview `Upsert` or `Remove`. Multiple records of the selected type are rejected rather than altered in bulk. CNAME conflicts with other record types are rejected.
3. Approve the exact host/zone/name/type/value. Applied changes export prior record metadata to a unique file under the protected `DNSBackups` directory.
4. Verify the local DNS record, AD-integrated replication where applicable, and resolution against another DNS server/client. Check the application's actual connection and allow for cache/TTL effects.

This pack excludes zone apex, underscore-prefixed infrastructure names and `_msdcs` zones. It does not manage PTR/AAAA/SRV records, scavenging, zone transfer configuration or DNSSEC. It does not guarantee that an application record is nonsensitive; reviewers must identify DC/CA/service hostnames and deny inappropriate changes.

To reverse an A/CNAME change, inspect the recorded old values and submit a new approved upsert/removal. CLIXML is evidence, not an automatically restorable live DNS object. When exact TTL/aging metadata restoration is required, use a reviewed native DNS recovery procedure. Keep authoritative zone backups separately. Do not blindly import every serialized object and overwrite a zone.

## GPO Inspection And Backups

Supply `Server`, exact `GpoId` and `TargetOU`. The target must be an existing OU. `Inspect` outputs GPO metadata, direct links on that OU and an XML GPO report. Export large reports through encrypted logging rather than rely on the console output limit.

`Backup` needs `Apply=true` because it writes artifacts. It creates a unique protected backup directory containing the native GPO backup and a separate direct-link snapshot. Copy it off-host through the approved encrypted backup process.

GPO backup is not a full AD/GPO disaster-recovery backup. OU links, precedence, enforced state, WMI filters, inheritance and external dependencies must be recorded separately. The link snapshot does not include all inherited link topology.

## GPO Link Changes

1. Inspect policy content, permissions, existing direct/inherited links and OU population.
2. Back up and confirm a test/canary OU outcome before touching a production OU.
3. Preview `Link` or `Unlink`; approve the GPO GUID and exact OU.
4. Applied actions take a GPO backup and direct-link snapshot first. A new link is enabled, not enforced, and uses the native default placement/order. If already linked, `Link` refuses to change its order/state implicitly.
5. Verify link order and effective policy with `gpresult`/Resultant Set of Policy on representative machines/users. Replication success and a link's existence do not prove desired effective policy.

Default Domain Policy and Default Domain Controllers Policy are excluded from modifications. Domain-root/site linking, policy setting changes, inheritance changes, link reordering and automatic GPO restore are outside this first pack.

Rollback needs a new reviewed change. Unlink a newly added link, or restore an old link's enabled/enforced/order state from the captured snapshot with authorized native GPO tools. Relinking through this document alone will not reproduce the old order/enforced state. Do not use `Restore-GPO` as a substitute for link restoration: policy content and link topology are separate.

`RefreshPolicy` in the WSUS client document applies **all** computer policy, not only Windows Update settings. Approve it as a general computer-policy operation; it does not refresh a logged-on user's policy or guarantee restart/logoff-dependent policy completion.