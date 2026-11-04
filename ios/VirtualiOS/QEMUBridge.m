#import "QEMUBridge.h"

#import <dlfcn.h>
#import <pthread.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <errno.h>
#import <stdlib.h>
#import <string.h>
#import <sys/time.h>
#import <unistd.h>

typedef int (*QEMUInitFunction)(int, const char *[], const char *[]);
typedef void (*QEMUMainLoopFunction)(void);
typedef void (*QEMUCleanupFunction)(void);

extern const char **environ;

typedef struct {
    void *library;
    QEMUInitFunction initialize;
    QEMUMainLoopFunction mainLoop;
    QEMUCleanupFunction cleanup;
    int argumentCount;
    char **arguments;
} QEMUThreadContext;

static pthread_mutex_t QEMUStateLock = PTHREAD_MUTEX_INITIALIZER;
static BOOL QEMUIsRunning;

static NSError *QEMUError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"VirtualiOS.QEMUBridge"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static void FreeThreadContext(QEMUThreadContext *context) {
    for (int index = 0; index < context->argumentCount; index++) {
        free(context->arguments[index]);
    }
    free(context->arguments);
    free(context);
}

static void *RunQEMU(void *opaqueContext) {
    QEMUThreadContext *context = opaqueContext;
    int status = context->initialize(context->argumentCount,
                                     (const char **)context->arguments,
                                     environ);
    if (status == 0) {
        context->mainLoop();
    }
    context->cleanup();
    dlclose(context->library);
    FreeThreadContext(context);

    pthread_mutex_lock(&QEMUStateLock);
    QEMUIsRunning = NO;
    pthread_mutex_unlock(&QEMUStateLock);
    return NULL;
}

static BOOL WriteAll(int socketDescriptor, const void *bytes, size_t length) {
    const uint8_t *cursor = bytes;
    while (length > 0) {
        ssize_t written = send(socketDescriptor, cursor, length, 0);
        if (written <= 0) {
            return NO;
        }
        cursor += written;
        length -= (size_t)written;
    }
    return YES;
}

static NSString *ReadLine(int socketDescriptor) {
    NSMutableData *data = [NSMutableData data];
    uint8_t byte = 0;
    while (recv(socketDescriptor, &byte, 1, 0) == 1) {
        if (byte == '\n') {
            break;
        }
        [data appendBytes:&byte length:1];
    }
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static NSDictionary<NSString *, id> *ReadResponse(int socketDescriptor) {
    while (YES) {
        NSString *line = ReadLine(socketDescriptor);
        if (line.length == 0) {
            return nil;
        }
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([value isKindOfClass:NSDictionary.class] &&
            (value[@"return"] != nil || value[@"error"] != nil)) {
            return value;
        }
    }
}

@implementation QEMUBridge

+ (BOOL)startWithLibraryURL:(NSURL *)libraryURL
                  arguments:(NSArray<NSString *> *)arguments
                      error:(NSError **)error {
    pthread_mutex_lock(&QEMUStateLock);
    if (QEMUIsRunning) {
        pthread_mutex_unlock(&QEMUStateLock);
        if (error) {
            *error = QEMUError(1, @"A QEMU guest is already running.");
        }
        return NO;
    }
    pthread_mutex_unlock(&QEMUStateLock);

    void *library = dlopen(libraryURL.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!library) {
        if (error) {
            *error = QEMUError(2, [NSString stringWithUTF8String:dlerror() ?: "Unable to load QEMU."]);
        }
        return NO;
    }

    QEMUInitFunction initialize = (QEMUInitFunction)dlsym(library, "qemu_init");
    QEMUMainLoopFunction mainLoop = (QEMUMainLoopFunction)dlsym(library, "qemu_main_loop");
    QEMUCleanupFunction cleanup = (QEMUCleanupFunction)dlsym(library, "qemu_cleanup");
    if (!initialize || !mainLoop || !cleanup) {
        NSString *message = [NSString stringWithUTF8String:dlerror() ?: "QEMU lifecycle symbols are missing."];
        dlclose(library);
        if (error) {
            *error = QEMUError(3, message);
        }
        return NO;
    }

    QEMUThreadContext *context = calloc(1, sizeof(QEMUThreadContext));
    context->library = library;
    context->initialize = initialize;
    context->mainLoop = mainLoop;
    context->cleanup = cleanup;
    context->argumentCount = (int)arguments.count;
    context->arguments = calloc(arguments.count + 1, sizeof(char *));
    for (NSUInteger index = 0; index < arguments.count; index++) {
        context->arguments[index] = strdup(arguments[index].UTF8String);
    }

    pthread_mutex_lock(&QEMUStateLock);
    QEMUIsRunning = YES;
    pthread_mutex_unlock(&QEMUStateLock);

    pthread_t thread;
    int result = pthread_create(&thread, NULL, RunQEMU, context);
    if (result != 0) {
        pthread_mutex_lock(&QEMUStateLock);
        QEMUIsRunning = NO;
        pthread_mutex_unlock(&QEMUStateLock);
        dlclose(library);
        FreeThreadContext(context);
        if (error) {
            *error = QEMUError(result, @"Unable to create the QEMU worker thread.");
        }
        return NO;
    }
    pthread_detach(thread);
    return YES;
}

+ (BOOL)sendCommand:(NSDictionary<NSString *,id> *)command
           toSocket:(NSString *)socketPath
           response:(NSDictionary<NSString *,id> * _Nullable * _Nullable)response
              error:(NSError **)error {
    int socketDescriptor = socket(AF_UNIX, SOCK_STREAM, 0);
    if (socketDescriptor < 0) {
        if (error) {
            *error = QEMUError(errno, @"Unable to create the QMP socket.");
        }
        return NO;
    }

    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    if (socketPath.length >= sizeof(address.sun_path)) {
        close(socketDescriptor);
        if (error) {
            *error = QEMUError(4, @"The QMP socket path is too long.");
        }
        return NO;
    }
    strlcpy(address.sun_path, socketPath.fileSystemRepresentation, sizeof(address.sun_path));

    struct timeval timeout = {.tv_sec = 2, .tv_usec = 0};
    setsockopt(socketDescriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(socketDescriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

    if (connect(socketDescriptor, (struct sockaddr *)&address, sizeof(address)) != 0) {
        close(socketDescriptor);
        if (error) {
            *error = QEMUError(errno, @"Unable to connect to the QEMU monitor.");
        }
        return NO;
    }

    ReadLine(socketDescriptor);
    NSDictionary *capabilities = @{@"execute": @"qmp_capabilities"};
    NSData *capabilityData = [NSJSONSerialization dataWithJSONObject:capabilities options:0 error:nil];
    NSMutableData *capabilityMessage = [capabilityData mutableCopy];
    [capabilityMessage appendBytes:"\r\n" length:2];
    if (!WriteAll(socketDescriptor, capabilityMessage.bytes, capabilityMessage.length) || !ReadResponse(socketDescriptor)) {
        close(socketDescriptor);
        if (error) {
            *error = QEMUError(5, @"QEMU did not accept QMP capabilities.");
        }
        return NO;
    }

    NSData *commandData = [NSJSONSerialization dataWithJSONObject:command options:0 error:error];
    if (!commandData) {
        close(socketDescriptor);
        return NO;
    }
    NSMutableData *commandMessage = [commandData mutableCopy];
    [commandMessage appendBytes:"\r\n" length:2];
    if (!WriteAll(socketDescriptor, commandMessage.bytes, commandMessage.length)) {
        close(socketDescriptor);
        if (error) {
            *error = QEMUError(6, @"Unable to send a command to QEMU.");
        }
        return NO;
    }

    NSDictionary *commandResponse = ReadResponse(socketDescriptor);
    close(socketDescriptor);
    if (!commandResponse || commandResponse[@"error"]) {
        if (error) {
            *error = QEMUError(7, commandResponse[@"error"][@"desc"] ?: @"QEMU rejected the command.");
        }
        return NO;
    }
    if (response) {
        *response = commandResponse;
    }
    return YES;
}

+ (BOOL)isRunning {
    pthread_mutex_lock(&QEMUStateLock);
    BOOL running = QEMUIsRunning;
    pthread_mutex_unlock(&QEMUStateLock);
    return running;
}

@end