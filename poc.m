/*
 * Minimal InstallCoordination delivery path.
 *
 * payloadRoot must contain PromiseStaging, DataPromises, and Coordinators.
 * This function does nothing until the caller invokes stage_installcoord_payload().
 */

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <stdbool.h>
#import <stdint.h>
#import <xpc/xpc.h>

typedef void *container_query_t;
static NSMutableArray<NSValue *> *activeQueries;

static BOOL ActivateInstallCoordDomain(NSString *domain)
{
    void *lib = dlopen(
        "/usr/lib/system/libsystem_containermanager.dylib",
        RTLD_NOW | RTLD_LOCAL);
    container_query_t (*create)(void) =
        dlsym(lib, "container_query_create");
    void (*setClass)(container_query_t, uint64_t) =
        dlsym(lib, "container_query_set_class");
    void (*setGroup)(container_query_t, xpc_object_t) =
        dlsym(lib, "container_query_set_group_identifiers");
    void (*setFlags)(container_query_t, uint64_t) =
        dlsym(lib, "container_query_operation_set_flags");
    void (*setPart)(container_query_t, uint64_t) =
        dlsym(lib, "container_query_operation_set_part");
    void (*setDomain)(container_query_t, const char *) =
        dlsym(lib, "container_query_operation_set_part_domain");
    void *(*result)(container_query_t) =
        dlsym(lib, "container_query_get_single_result");
    bool (*activate)(void *, bool) = dlsym(
        lib, "container_object_sandbox_extension_activate");

    if (create == NULL || setClass == NULL || setGroup == NULL ||
        setFlags == NULL || setPart == NULL || setDomain == NULL ||
        result == NULL || activate == NULL) {
        return NO;
    }

    container_query_t query = create();
    setClass(query, 13);
    xpc_object_t group = xpc_string_create(
        "systemgroup.com.apple.installcoordinationd");
    setGroup(query, group);
    setFlags(query, (UINT64_C(1) << 39) | (UINT64_C(1) << 32));
    setPart(query, 3);                          // Library/Caches
    setDomain(query, domain.fileSystemRepresentation);

    void *object = result(query);
    if (object == NULL || !activate(object, false)) {
        return NO;
    }
    if (activeQueries == nil) {
        activeQueries = [NSMutableArray array];
    }
    [activeQueries addObject:[NSValue valueWithPointer:query]];
    return YES;                                 // keep query alive
}

static BOOL CopyContents(NSString *source, NSString *destination,
                         NSError **error)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:source
                                                         error:error];
    if (names == nil) {
        return NO;
    }
    for (NSString *name in names) {
        NSString *from = [source stringByAppendingPathComponent:name];
        NSString *to = [destination stringByAppendingPathComponent:name];
        if ([fm fileExistsAtPath:to] || ![fm copyItemAtPath:from
                                       toPath:to error:error]) {
            return NO;
        }
    }
    return YES;
}

BOOL stage_installcoord_payload(NSString *payloadRoot, NSError **error)
{
    NSArray<NSString *> *parts = @[
        @"PromiseStaging", @"DataPromises", @"Coordinators"
    ];
    for (NSString *part in parts) {
        NSString *domain = [@"../InstallCoordination"
            stringByAppendingPathComponent:part];
        if (!ActivateInstallCoordDomain(domain)) {
            return NO;                          // patched on 24A5408d
        }
    }

    NSString *stateRoot =
        @"/private/var/containers/Shared/SystemGroup/"
         "systemgroup.com.apple.installcoordinationd/Library/"
         "InstallCoordination";

    // Commit order matters. The coordinator is the final commit record.
    for (NSString *part in parts) {
        if (!CopyContents(
                [payloadRoot stringByAppendingPathComponent:part],
                [stateRoot stringByAppendingPathComponent:part], error)) {
            return NO;
        }
    }
    return YES;
}
