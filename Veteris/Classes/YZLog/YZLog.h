#import "../../AntiDebug.h"

#ifdef DEBUG
#define debugLog(...) [YZLog debugLog:[NSString stringWithFormat:@"%@:%@", @__FILE__, @__LINE__] message:[NSString stringWithFormat:__VA_ARGS__]]
#else
#define debugLog(...) ((void)0)
#endif

@interface YZLog : NSObject
#ifdef DEBUG
+ (void)debugLog:(NSString *)location message:(NSString *)message;
#endif
@end