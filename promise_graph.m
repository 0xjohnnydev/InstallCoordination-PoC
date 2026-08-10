/* Minimal daemon-side class names used in a forged promise graph. */

#import <Foundation/Foundation.h>

@interface IXSDataPromise : NSObject <NSSecureCoding>
@property(nonatomic, strong) id seed;
@property(nonatomic) BOOL complete;
@property(nonatomic) double progress;
@end

@implementation IXSDataPromise
+ (BOOL)supportsSecureCoding { return YES; }
- (instancetype)initWithCoder:(NSCoder *)coder
{
    (void)coder;
    return [super init];
}
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:self.seed forKey:@"seed"];
    [coder encodeObject:nil forKey:@"error"];
    [coder encodeObject:@0 forKey:@"errorSourceIdentifier"];
    [coder encodeBool:YES forKey:@"isTracked"];
    [coder encodeDouble:self.progress forKey:@"percentComplete"];
    [coder encodeBool:self.complete forKey:@"complete"];
}
@end

@interface IXSOwnedDataPromise : IXSDataPromise
@property(nonatomic, copy) NSString *relativePath;
@end

@implementation IXSOwnedDataPromise
+ (BOOL)supportsSecureCoding { return YES; }
- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    [coder encodeObject:self.relativePath forKey:@"relativeStagedPath"];
    [coder encodeBool:NO forKey:@"stagedPathMayNotExistWhenAwakening"];
    [coder encodeObject:nil forKey:@"stagingLocation"];
}
@end

@interface IXSPlaceholder : IXSOwnedDataPromise
@property(nonatomic, strong) NSUUID *localizationPromiseUUID;
@end

@implementation IXSPlaceholder
+ (BOOL)supportsSecureCoding { return YES; }
- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    [coder encodeObject:nil forKey:@"iconPromiseUUID"];
    [coder encodeObject:nil forKey:@"iconResourcesPromiseUUID"];
    [coder encodeObject:nil forKey:@"infoPlistIconContentPromiseUUID"];
    [coder encodeObject:nil forKey:@"entitlementsPromiseUUID"];
    [coder encodeObject:nil forKey:@"infoPlistLoctablePromiseUUID"];
    [coder encodeObject:nil forKey:@"metadataPromiseUUID"];
    [coder encodeObject:nil forKey:@"sinfPromiseUUID"];
    [coder encodeObject:self.localizationPromiseUUID
                 forKey:@"localizationDictionaryPromiseUUID"];
    [coder encodeObject:nil forKey:@"appExtensionPlaceholdersPromiseUUIDs"];
    [coder encodeBool:NO forKey:@"sentDidBegin"];
    [coder encodeBool:YES forKey:@"configurationComplete"];
    [coder encodeObject:nil forKey:@"attributes"];
    [coder encodeBool:NO
               forKey:@"creatorHadWebPlaceholderInstallEntitlement"];
}
@end

@interface IXSPromisedInMemoryDictionary : IXSOwnedDataPromise
@end
@implementation IXSPromisedInMemoryDictionary
+ (BOOL)supportsSecureCoding { return YES; }
@end

NSData *ArchivePlaceholder(id placeholderSeed, NSUUID *dictionaryUUID,
                           NSError **error)
{
    IXSPlaceholder *parent = [IXSPlaceholder new];
    parent.seed = placeholderSeed;
    parent.complete = NO;                       // daemon materializes it
    parent.progress = 0;
    parent.localizationPromiseUUID = dictionaryUUID;
    return [NSKeyedArchiver archivedDataWithRootObject:parent
                                 requiringSecureCoding:YES error:error];
}

NSData *ArchiveDictionary(id dictionarySeed, NSString *relativePath,
                          NSError **error)
{
    IXSPromisedInMemoryDictionary *child =
        [IXSPromisedInMemoryDictionary new];
    child.seed = dictionarySeed;
    child.complete = YES;
    child.progress = 1;
    child.relativePath = relativePath;
    return [NSKeyedArchiver archivedDataWithRootObject:child
                                 requiringSecureCoding:YES error:error];
}
