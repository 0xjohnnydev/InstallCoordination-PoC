# InstallCoordination persisted-state PoC

This chain writes attacker-built InstallCoordination state, lets
`installcoordinationd` restore it, and reaches a final-symlink write during
placeholder localization materialization.

The chain has four separate defects.

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
child.relativePath = @"Data.data";
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
5. Let `installcoordinationd` restore the staged graph.

The code does not stage anything until the caller invokes the exported
function. It expects `payloadRoot` to contain `PromiseStaging`, `DataPromises`,
and `Coordinators`.

## Result and patch status

The safe runtime test produced an exact attacker-selected binary plist at its
scratch symlink target on `iPhone12,1`, build `24A5380h`. It verified and then
restored the target.

This result proves a chosen-content write with the daemon's filesystem
authority. It does not prove UID 0 code execution, unsigned-code execution,
AMFI bypass, or arbitrary filesystem read/write.

Build `24A5408d` patches both known entry defects. Class-13 no longer grants
the proven nonzero-access request, and `partDomain` rejects traversal-shaped
values. The persisted restore and final-symlink logic remain, but the known
normal-app route can no longer reach their files.
