# InstallCoordination persisted-state PoC

This chain writes attacker-built InstallCoordination state, lets
`installcoordinationd` restore it, and reaches a final-symlink write during
placeholder localization materialization.

The chain has four separate defects.

## Paths exposed by the entry bugs

The direct class-13 request starts at this system-group part:

```text
/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.installcoordinationd/Library/Caches/
```

The unchecked `partDomain` value redirected the extension to these persisted
state directories:

```text
/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.installcoordinationd/Library/InstallCoordination/PromiseStaging/
/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.installcoordinationd/Library/InstallCoordination/DataPromises/
/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.installcoordinationd/Library/InstallCoordination/Coordinators/
```

On an affected build, the app can read and write those directories while the
extension is active. The extension does not grant the whole system-group root
or arbitrary `/private/var` access.

The final-symlink bug is a second authority step. It redirects one daemon
binary-plist write to a selected path that `installcoordinationd` is permitted
to open. The proved target was a random scratch file inside the
InstallCoordination system group. No test proved a write to a root-only path or
to the MobileGestalt cache plist through this chain.

## 1. Class-13 authorization

An ordinary app could request read/write access to the InstallCoordination
system group:

```objc
setClass(query, 13);
setGroup(query,
    xpc_string_create("systemgroup.com.apple.installcoordinationd"));
setFlags(query, (UINT64_C(1) << 39) | (UINT64_C(1) << 32));
setPart(query, 3); // Library/Caches
```

The old well-known-container exception also authorized nonzero access.

## 2. Unchecked `partDomain`

The query accepted traversal in the domain value:

```objc
setDomain(query, "../InstallCoordination/DataPromises");
```

The same request shape exposed `PromiseStaging` and `Coordinators`. The
sandbox extension therefore covered persisted daemon state outside
`Library/Caches`.

[`poc.m`](poc.m) contains the class-13 request and the three-directory staging
order.

## 3. Persisted graph trust

The daemon restored archived identities, UUIDs, promise links, creator fields,
and install state without rebinding them to a trusted current client.

The useful graph contains an incomplete placeholder and a completed dictionary
promise:

```objc
IXSPlaceholder *parent = [IXSPlaceholder new];
parent.seed = placeholderSeed;
parent.complete = NO;
parent.localizationPromiseUUID = dictionaryUUID;

IXSPromisedInMemoryDictionary *child =
    [IXSPromisedInMemoryDictionary new];
child.seed = dictionarySeed;
child.complete = YES;
child.relativePath = @"CodexDictionary-<compact-uuid>.plist";
```

The archive must use the daemon's exact class names and keyed fields.
[`promise_graph.m`](promise_graph.m) contains the minimal encoder classes.

## 4. Final-symlink write

The restored placeholder materializes localization data at:

```text
<bundle>/<locale>.lproj/InfoPlist.strings
```

If the final leaf is a symlink, the daemon's property-list write follows it.
The runtime test used a scratch target and verified the exact binary plist.

The coordinator must be copied last because it commits the graph:

```objc
copy(payload/PromiseStaging, state/PromiseStaging);
copy(payload/DataPromises,  state/DataPromises);
copy(payload/Coordinators,  state/Coordinators);
```

## Use

1. Add `poc.m` and `promise_graph.m` to an Objective-C iOS target.
2. Build the exact promise seeds and archives for the target build.
3. Prepare the final localization leaf as a symlink to a safe scratch file.
4. Call `stage_installcoord_payload(payloadRoot, &error)`.
5. Cause `installcoordinationd` to reload its saved state.
6. Run a verification and restoration pass after the daemon materializes the
   placeholder.

The code does not stage anything until the caller invokes the exported
function. It expects `payloadRoot` to contain `PromiseStaging`, `DataPromises`,
and `Coordinators`. The published files are minimal mechanism excerpts. They
do not include the full target-specific seed builder, app UI, daemon-reload
harness, or verification journal used by the preserved runtime test.

The lab run stopped `installcoordinationd` and let launchd restart it. A normal
app cannot directly perform that host-controlled step. A natural daemon restart
can also load the graph, but its timing is not deterministic.

`poc.m` now removes files that it created when staging fails. This cleanup is
best effort. A concurrent daemon reload can consume or move state before the
app removes it, so use only a disposable test graph and a journaled scratch
target.

## Result and patch status

The safe runtime test produced an exact attacker-selected binary plist at its
scratch symlink target on `iPhone12,1`, build `24A5380h`. It verified and then
restored the target. The preserved replay logged a 156-byte changed plist,
`semantic_match=true`, `proof=true`, verified restoration, and complete staged
artifact cleanup. The evidence file is
`iphone11-installcoord-schema7-replay2-20260710-041649.log`.

The class-13 entry and all three traversal subextensions were also active in
that run. Separate entry tests created, read back, and removed a direct canary
in the InstallCoordination state directory.

This result proves a chosen-content write with the daemon's filesystem
authority. It does not prove UID 0 code execution, unsigned-code execution,
AMFI bypass, or arbitrary filesystem read/write.

These tests establish only the named iOS 27.0 beta build. The earliest affected
version is unknown.

Build `24A5408d` patches both known entry defects. Class-13 no longer grants
the proven nonzero-access request, and `partDomain` rejects traversal-shaped
values. The persisted restore and final-symlink logic remain, but the known
normal-app route can no longer reach their files.

The new extension core retains a proxied-client branch. It does not restore
the proven direct normal-app chain because the earlier nonzero-access policy
gate and the `partDomain` parser reject that request.
