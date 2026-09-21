// DevicePickerViewController.m
// Direct Instant Share to Android interface.
// Hosts an unsandboxed local HTTP server for zero-setup file transfers to any Android device.
// Author: Sanket Yadav

#import "DevicePickerViewController.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <CoreImage/CoreImage.h>
#import <spawn.h>

extern char **environ;

@implementation BSSimpleHTTPServer {
    int _serverFd;
    int _boundPort;
    BOOL _running;
    NSMutableArray<NSDictionary *> *_fileItems;
}

+ (instancetype)sharedServer {
    static BSSimpleHTTPServer *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [BSSimpleHTTPServer new]; });
    return s;
}

- (NSString *)connectionType {
    struct ifaddrs *interfaces = NULL;
    struct ifaddrs *temp_addr = NULL;
    NSString *type = @"Wi-Fi";
    if (getifaddrs(&interfaces) == 0) {
        temp_addr = interfaces;
        while (temp_addr != NULL) {
            if (temp_addr->ifa_addr && temp_addr->ifa_addr->sa_family == AF_INET) {
                NSString *name = [NSString stringWithUTF8String:temp_addr->ifa_name];
                if ([name hasPrefix:@"bridge"]) {
                    type = @"Personal Hotspot";
                    break;
                } else if ([name hasPrefix:@"en"]) {
                    type = @"Wi-Fi";
                }
            }
            temp_addr = temp_addr->ifa_next;
        }
    }
    if (interfaces) freeifaddrs(interfaces);
    return type;
}

- (NSString *)localIPAddress {
    NSString *address = nil;
    struct ifaddrs *interfaces = NULL;
    struct ifaddrs *temp_addr = NULL;
    if (getifaddrs(&interfaces) == 0) {
        temp_addr = interfaces;
        while (temp_addr != NULL) {
            if (temp_addr->ifa_addr && temp_addr->ifa_addr->sa_family == AF_INET) {
                NSString *name = [NSString stringWithUTF8String:temp_addr->ifa_name];
                // ONLY accept Personal Hotspot (bridge100, bridge101) or Wi-Fi (en0, en1).
                // Do NOT include ap0 (AWDL/AirDrop), pdp_ip (Cellular), or lo0 (Loopback).
                if ([name isEqualToString:@"bridge100"] || [name isEqualToString:@"bridge101"] ||
                    [name isEqualToString:@"en0"] || [name isEqualToString:@"en1"]) {
                    struct sockaddr_in *saddr = (struct sockaddr_in *)temp_addr->ifa_addr;
                    NSString *ip = [NSString stringWithUTF8String:inet_ntoa(saddr->sin_addr)];
                    if (ip && ![ip isEqualToString:@"127.0.0.1"] && ![ip hasPrefix:@"169.254."]) {
                        if ([name hasPrefix:@"bridge"]) {
                            address = ip;
                            break; // Prioritize Personal Hotspot
                        } else if (!address) {
                            address = ip;
                        }
                    }
                }
            }
            temp_addr = temp_addr->ifa_next;
        }
    }
    if (interfaces) freeifaddrs(interfaces);
    return address;
}

- (NSString *)mimeTypeForExtension:(NSString *)ext {
    NSString *e = [ext lowercaseString];
    if ([e isEqualToString:@"jpg"] || [e isEqualToString:@"jpeg"]) return @"image/jpeg";
    if ([e isEqualToString:@"png"])  return @"image/png";
    if ([e isEqualToString:@"gif"])  return @"image/gif";
    if ([e isEqualToString:@"webp"]) return @"image/webp";
    if ([e isEqualToString:@"heic"] || [e isEqualToString:@"heif"]) return @"image/heic";
    if ([e isEqualToString:@"mp4"])  return @"video/mp4";
    if ([e isEqualToString:@"mov"])  return @"video/quicktime";
    if ([e isEqualToString:@"m4v"])  return @"video/x-m4v";
    if ([e isEqualToString:@"mp3"])  return @"audio/mpeg";
    if ([e isEqualToString:@"m4a"])  return @"audio/mp4";
    if ([e isEqualToString:@"wav"])  return @"audio/wav";
    if ([e isEqualToString:@"pdf"])  return @"application/pdf";
    if ([e isEqualToString:@"zip"])  return @"application/zip";
    if ([e isEqualToString:@"txt"])  return @"text/plain";
    if ([e isEqualToString:@"apk"])  return @"application/vnd.android.package-archive";
    if ([e isEqualToString:@"docx"]) return @"application/vnd.openxmlformats-officedocument.wordprocessingml.document";
    if ([e isEqualToString:@"xlsx"]) return @"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";
    return @"application/octet-stream";
}

// ── Background Server in SpringBoard (Unsandboxed) ───────────────────────────
- (void)startListening {
    if (_running) return;

    _serverFd = socket(AF_INET, SOCK_STREAM, 0);
    if (_serverFd < 0) {
        NSLog(@"[BlueShare] SpringBoard socket() error: %s", strerror(errno));
        return;
    }

    int opt = 1;
    setsockopt(_serverFd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
#ifdef SO_REUSEPORT
    setsockopt(_serverFd, SOL_SOCKET, SO_REUSEPORT, &opt, sizeof(opt));
#endif

    int ports[] = {8765, 8766, 8888, 8080};
    BOOL bound = NO;
    for (int i = 0; i < 4; i++) {
        int p = ports[i];
        struct sockaddr_in serv;
        memset(&serv, 0, sizeof(serv));
        serv.sin_family = AF_INET;
        serv.sin_addr.s_addr = INADDR_ANY;
        serv.sin_port = htons(p);

        if (bind(_serverFd, (struct sockaddr *)&serv, sizeof(serv)) == 0) {
            _boundPort = p;
            bound = YES;
            break;
        }
    }

    if (!bound || listen(_serverFd, 15) < 0) {
        NSLog(@"[BlueShare] SpringBoard bind/listen failed: %s", strerror(errno));
        close(_serverFd);
        _serverFd = 0;
        return;
    }

    _running = YES;
    NSLog(@"[BlueShare] SpringBoard server listening on port %d", _boundPort);

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self acceptLoop];
    });
}

// ── Server Accept Loop ────────────────────────────────────────────────────────
- (void)acceptLoop {
    while (_running) {
        struct sockaddr_in client_addr;
        socklen_t client_len = sizeof(client_addr);
        int clientFd = accept(_serverFd, (struct sockaddr *)&client_addr, &client_len);
        if (clientFd < 0) {
            if (!_running) break;
            continue;
        }

        // Handle connection on background thread
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSMutableData *reqData = [NSMutableData new];
            char buf[4096];
            ssize_t n = 0;

            // Read initial request bytes
            n = read(clientFd, buf, sizeof(buf));
            if (n <= 0) {
                close(clientFd);
                return;
            }
            [reqData appendBytes:buf length:n];

            NSString *reqHead = [[NSString alloc] initWithData:reqData encoding:NSUTF8StringEncoding];
            if (!reqHead) reqHead = [[NSString alloc] initWithData:reqData encoding:NSISOLatin1StringEncoding] ?: @"";

            // 1. Healthcheck / Ping endpoint
            if ([reqHead containsString:@"GET /ping"]) {
                const char *resp = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\nPONG";
                write(clientFd, resp, strlen(resp));
                close(clientFd);
                return;
            }

            // 2. Register files endpoint (from sandboxed apps like Photos)
            if ([reqHead containsString:@"POST /register"]) {
                // Find start of JSON body
                NSRange bodyRange = [reqHead rangeOfString:@"\r\n\r\n"];
                NSData *jsonData = nil;
                if (bodyRange.location != NSNotFound) {
                    NSUInteger bodyOffset = bodyRange.location + 4;
                    if (reqData.length > bodyOffset) {
                        jsonData = [reqData subdataWithRange:NSMakeRange(bodyOffset, reqData.length - bodyOffset)];
                    }
                }

                if (jsonData) {
                    NSError *jErr = nil;
                    NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&jErr];
                    NSArray *files = payload[@"files"];
                    if (files && [files isKindOfClass:[NSArray class]]) {
                        @synchronized (self) {
                            self->_fileItems = [NSMutableArray new];
                            for (NSDictionary *f in files) {
                                NSString *path = f[@"path"];
                                NSString *name = f[@"name"] ?: @"file";
                                NSString *mime = f[@"mime"] ?: @"application/octet-stream";
                                NSData *fileData = nil;
                                if (path.length > 0) {
                                    fileData = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
                                }
                                if (fileData && fileData.length > 0) {
                                    [self->_fileItems addObject:@{
                                        @"name": name,
                                        @"mime": mime,
                                        @"data": fileData,
                                        @"index": @(self->_fileItems.count)
                                    }];
                                }
                            }
                        }
                    }
                }

                const char *resp = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{\"status\":\"ok\"}";
                write(clientFd, resp, strlen(resp));
                close(clientFd);
                return;
            }

            // 3. Raw Data Upload endpoint (fallback for direct memory upload)
            if ([reqHead containsString:@"POST /upload"]) {
                // Parse Content-Length and metadata
                NSRange clRange = [reqHead rangeOfString:@"Content-Length: " options:NSCaseInsensitiveSearch];
                NSInteger contentLength = 0;
                if (clRange.location != NSNotFound) {
                    NSString *tail = [reqHead substringFromIndex:clRange.location + 16];
                    NSScanner *scan = [NSScanner scannerWithString:tail];
                    [scan scanInteger:&contentLength];
                }

                NSString *fileName = @"photo.jpg";
                NSRange fnRange = [reqHead rangeOfString:@"X-File-Name: " options:NSCaseInsensitiveSearch];
                if (fnRange.location != NSNotFound) {
                    NSString *tail = [reqHead substringFromIndex:fnRange.location + 13];
                    NSRange endLine = [tail rangeOfString:@"\r\n"];
                    if (endLine.location != NSNotFound) fileName = [tail substringToIndex:endLine.location];
                }

                NSString *mimeType = [self mimeTypeForExtension:fileName.pathExtension];

                NSRange bodyRange = [reqHead rangeOfString:@"\r\n\r\n"];
                NSMutableData *bodyData = [NSMutableData new];
                if (bodyRange.location != NSNotFound) {
                    NSUInteger offset = bodyRange.location + 4;
                    if (reqData.length > offset) {
                        [bodyData appendData:[reqData subdataWithRange:NSMakeRange(offset, reqData.length - offset)]];
                    }
                }

                while (bodyData.length < contentLength) {
                    ssize_t r = read(clientFd, buf, sizeof(buf));
                    if (r <= 0) break;
                    [bodyData appendBytes:buf length:r];
                }

                if (bodyData.length > 0) {
                    @synchronized (self) {
                        self->_fileItems = [NSMutableArray new];
                        [self->_fileItems addObject:@{
                            @"name": fileName,
                            @"mime": mimeType,
                            @"data": [bodyData copy],
                            @"index": @0
                        }];
                    }
                }

                const char *resp = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{\"status\":\"ok\"}";
                write(clientFd, resp, strlen(resp));
                close(clientFd);
                return;
            }

            // 4. Download / Raw media streams for Android
            if ([reqHead containsString:@"GET /download"] || [reqHead containsString:@"GET /raw"]) {
                NSDictionary *item = nil;
                @synchronized (self) {
                    item = self->_fileItems.firstObject;
                    NSRange idRange = [reqHead rangeOfString:@"id="];
                    if (idRange.location != NSNotFound) {
                        NSString *tail = [reqHead substringFromIndex:idRange.location + 3];
                        NSScanner *scan = [NSScanner scannerWithString:tail];
                        NSInteger reqIdx = 0;
                        if ([scan scanInteger:&reqIdx] && reqIdx >= 0 && reqIdx < (NSInteger)self->_fileItems.count) {
                            item = self->_fileItems[reqIdx];
                        }
                    }
                }

                if (item) {
                    NSData *data = item[@"data"];
                    NSString *mime = item[@"mime"];
                    NSString *name = item[@"name"];
                    BOOL isDownload = [reqHead containsString:@"GET /download"];

                    NSString *headers = [NSString stringWithFormat:
                        @"HTTP/1.1 200 OK\r\n"
                        @"Content-Type: %@\r\n"
                        @"Content-Length: %lu\r\n"
                        @"%@"
                        @"Access-Control-Allow-Origin: *\r\n"
                        @"Connection: close\r\n\r\n",
                        mime, (unsigned long)data.length,
                        isDownload ? [NSString stringWithFormat:@"Content-Disposition: attachment; filename=\"%@\"\r\n", name] : @""];
                    NSData *hdrData = [headers dataUsingEncoding:NSUTF8StringEncoding];
                    write(clientFd, hdrData.bytes, hdrData.length);
                    write(clientFd, data.bytes, data.length);
                } else {
                    const char *resp = "HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\nFile Not Found";
                    write(clientFd, resp, strlen(resp));
                }
                close(clientFd);
                return;
            }

            // 5. Landing Page for Android Browser / Camera
            NSMutableString *bodyContent = [NSMutableString new];
            NSString *autoScript = @"";

            @synchronized (self) {
                if (self->_fileItems.count == 1) {
                    NSDictionary *item = self->_fileItems.firstObject;
                    NSString *name = item[@"name"];
                    NSString *mime = item[@"mime"];
                    NSData *data = item[@"data"];
                    NSString *fileSizeStr = [NSByteCountFormatter stringFromByteCount:data.length countStyle:NSByteCountFormatterCountStyleFile];

                    NSString *previewHTML = @"";
                    NSString *btnText = @"📥 Download to Android";

                    if ([mime hasPrefix:@"image/"]) {
                        previewHTML = @"<img src=\"/raw\" alt=\"Photo\" style=\"width:100%;max-height:340px;object-fit:cover;border-radius:14px;margin-bottom:18px;\">";
                        btnText = @"📥 Save to Android Gallery";
                    } else if ([mime hasPrefix:@"video/"]) {
                        previewHTML = @"<video controls autoplay muted playsinline src=\"/raw\" style=\"width:100%;max-height:300px;border-radius:14px;margin-bottom:18px;\"></video>";
                        btnText = @"📥 Save Video to Gallery";
                    } else if ([mime hasPrefix:@"audio/"]) {
                        previewHTML = @"<div style=\"font-size:54px;margin:12px 0;\">🎵</div><audio controls src=\"/raw\" style=\"width:100%;margin-bottom:18px;\"></audio>";
                        btnText = @"📥 Download Audio File";
                    } else {
                        previewHTML = [NSString stringWithFormat:@"<div style=\"font-size:54px;margin:14px 0;\">📄</div><h3 style=\"margin:0 0 6px;word-break:break-all;\">%@</h3><p style=\"color:#94a3b8;font-size:14px;margin-bottom:18px;\">Size: %@</p>", name, fileSizeStr];
                        btnText = [NSString stringWithFormat:@"📥 Download %@", name];
                    }

                    [bodyContent appendFormat:
                        @"%@"
                        @"<a href=\"/download\" class=\"btn dl-btn\" download=\"%@\">%@</a>"
                        @"<p class=\"hint\">✅ Saves directly to your Android device storage and appears in your Gallery / Downloads instantly.</p>",
                        previewHTML, name, btnText];

                    autoScript = [NSString stringWithFormat:
                        @"setTimeout(function(){"
                        @"  var a=document.createElement('a');a.href='/download';a.download='%@';document.body.appendChild(a);a.click();"
                        @"},600);", name];
                } else if (self->_fileItems.count > 1) {
                    [bodyContent appendFormat:@"<h3 style=\"margin:0 0 16px;\">Received %lu Items</h3>", (unsigned long)self->_fileItems.count];
                    for (NSDictionary *item in self->_fileItems) {
                        NSUInteger idx = [item[@"index"] unsignedIntegerValue];
                        NSString *name = item[@"name"];
                        NSString *mime = item[@"mime"];
                        NSData *data = item[@"data"];
                        NSString *sizeStr = [NSByteCountFormatter stringFromByteCount:data.length countStyle:NSByteCountFormatterCountStyleFile];

                        NSString *icon = [mime hasPrefix:@"image/"] ? @"🖼️" : ([mime hasPrefix:@"video/"] ? @"🎬" : @"📄");
                        [bodyContent appendFormat:
                            @"<div style=\"background:#334155;border-radius:12px;padding:12px;margin-bottom:10px;text-align:left;display:flex;align-items:center;justify-content:space-between;\">"
                            @"  <div style=\"overflow:hidden;padding-right:10px;\">"
                            @"    <div style=\"font-size:14px;font-weight:600;white-space:nowrap;text-overflow:ellipsis;overflow:hidden;\">%@ %@</div>"
                            @"    <div style=\"font-size:12px;color:#94a3b8;\">%@</div>"
                            @"  </div>"
                            @"  <a href=\"/download?id=%lu\" class=\"btn dl-btn\" download=\"%@\" style=\"width:auto;padding:8px 16px;font-size:13px;\">Save</a>"
                            @"</div>",
                            icon, name, sizeStr, (unsigned long)idx, name];
                    }

                    [bodyContent appendString:
                        @"<button onclick=\"downloadAll()\" class=\"btn\" style=\"margin-top:14px;cursor:pointer;\">📥 Save All to Android</button>"
                        @"<p class=\"hint\">Files save directly to Android Gallery and Downloads folder.</p>"];

                    autoScript =
                        @"function downloadAll(){"
                        @"  var links=document.querySelectorAll('.dl-btn');"
                        @"  links.forEach(function(l,i){"
                        @"    setTimeout(function(){ l.click(); }, i*600);"
                        @"  });"
                        @"}"
                        @"setTimeout(downloadAll, 800);";
                } else {
                    [bodyContent appendString:@"<p style=\"color:#94a3b8;\">Waiting for file from iPhone...</p>"];
                }
            }

            NSString *html = [NSString stringWithFormat:
                @"<!DOCTYPE html><html><head><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
                @"<title>BlueShare Transfer</title><style>"
                @"body{font-family:system-ui,-apple-system,sans-serif;background:#0f172a;color:#fff;text-align:center;padding:24px;margin:0}"
                @".card{background:#1e293b;border-radius:22px;padding:24px;max-width:380px;margin:20px auto;box-shadow:0 10px 30px rgba(0,0,0,0.5)}"
                @".badge{background:#10b981;color:#fff;font-weight:700;font-size:12px;padding:6px 14px;border-radius:30px;display:inline-block;margin-bottom:14px}"
                @"h2{margin:0 0 16px;font-size:20px;font-weight:700}"
                @".btn{display:block;width:100%%;box-sizing:border-box;background:#2563eb;color:#fff;text-decoration:none;padding:16px 0;border-radius:12px;font-weight:700;font-size:16px;border:none}"
                @".btn:active{background:#1d4ed8}"
                @".hint{color:#94a3b8;font-size:13px;margin-top:14px;line-height:1.4}"
                @"</style></head><body>"
                @"<div class=\"card\">"
                @"<div class=\"badge\">⚡ Instant Share to Android</div>"
                @"<h2>Received from iPhone</h2>"
                @"%@"
                @"</div>"
                @"<script>%@</script></body></html>",
                bodyContent, autoScript];

            NSData *htmlData = [html dataUsingEncoding:NSUTF8StringEncoding];
            NSString *headers = [NSString stringWithFormat:
                @"HTTP/1.1 200 OK\r\n"
                @"Content-Type: text/html; charset=utf-8\r\n"
                @"Content-Length: %lu\r\n"
                @"Access-Control-Allow-Origin: *\r\n"
                @"Connection: close\r\n\r\n",
                (unsigned long)htmlData.length];
            NSData *hdrData = [headers dataUsingEncoding:NSUTF8StringEncoding];
            write(clientFd, hdrData.bytes, hdrData.length);
            write(clientFd, htmlData.bytes, htmlData.length);
            close(clientFd);
        });
    }
}

// ── Client Helper: Check if SpringBoard server is active ──────────────────────
- (int)pingBackgroundServer {
    int ports[] = {8765, 8766, 8888, 8080};
    for (int i = 0; i < 4; i++) {
        int p = ports[i];
        int s = socket(AF_INET, SOCK_STREAM, 0);
        if (s < 0) continue;

        struct timeval tv;
        tv.tv_sec = 0;
        tv.tv_usec = 400000; // 400ms timeout
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

        struct sockaddr_in serv;
        memset(&serv, 0, sizeof(serv));
        serv.sin_family = AF_INET;
        serv.sin_port = htons(p);
        inet_pton(AF_INET, "127.0.0.1", &serv.sin_addr);

        if (connect(s, (struct sockaddr *)&serv, sizeof(serv)) == 0) {
            const char *ping = "GET /ping HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
            write(s, ping, strlen(ping));
            char resp[128];
            ssize_t n = read(s, resp, sizeof(resp) - 1);
            close(s);
            if (n > 0) {
                resp[n] = '\0';
                if (strstr(resp, "PONG") != NULL) {
                    return p;
                }
            }
        } else {
            close(s);
        }
    }
    return 0;
}

// ── Client Helper: Register files with SpringBoard server ─────────────────────
- (BOOL)registerFilesWithBackgroundServer:(NSArray<NSURL *> *)fileURLs port:(int)port errorReason:(NSString **)outError {
    NSMutableArray *filesArr = [NSMutableArray new];
    for (NSUInteger idx = 0; idx < fileURLs.count; idx++) {
        NSURL *u = fileURLs[idx];
        NSString *name = u.lastPathComponent ?: [NSString stringWithFormat:@"photo_%lu.jpg", (unsigned long)idx];
        NSString *mime = [self mimeTypeForExtension:name.pathExtension];
        [filesArr addObject:@{
            @"path": u.path ?: @"",
            @"name": name,
            @"mime": mime,
            @"index": @(idx)
        }];
    }

    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:@{@"files": filesArr} options:0 error:nil];
    if (!jsonData) return NO;

    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) return NO;

    struct timeval tv;
    tv.tv_sec = 2;
    tv.tv_usec = 0;
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    struct sockaddr_in serv;
    memset(&serv, 0, sizeof(serv));
    serv.sin_family = AF_INET;
    serv.sin_port = htons(port);
    inet_pton(AF_INET, "127.0.0.1", &serv.sin_addr);

    if (connect(s, (struct sockaddr *)&serv, sizeof(serv)) != 0) {
        close(s);
        return NO;
    }

    NSString *header = [NSString stringWithFormat:
        @"POST /register HTTP/1.1\r\n"
        @"Host: 127.0.0.1:%d\r\n"
        @"Content-Type: application/json\r\n"
        @"Content-Length: %lu\r\n"
        @"Connection: close\r\n\r\n",
        port, (unsigned long)jsonData.length];
    NSData *hdrData = [header dataUsingEncoding:NSUTF8StringEncoding];
    write(s, hdrData.bytes, hdrData.length);
    write(s, jsonData.bytes, jsonData.length);

    char resp[256];
    ssize_t n = read(s, resp, sizeof(resp) - 1);
    close(s);

    if (n > 0) {
        resp[n] = '\0';
        if (strstr(resp, "200 OK") != NULL) {
            return YES;
        }
    }

    // Fallback: If path registration did not work, upload raw data directly
    NSURL *firstURL = fileURLs.firstObject;
    NSData *firstData = [NSData dataWithContentsOfURL:firstURL];
    if (firstData && firstData.length > 0) {
        int us = socket(AF_INET, SOCK_STREAM, 0);
        if (us >= 0) {
            setsockopt(us, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
            setsockopt(us, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
            if (connect(us, (struct sockaddr *)&serv, sizeof(serv)) == 0) {
                NSString *uHdr = [NSString stringWithFormat:
                    @"POST /upload HTTP/1.1\r\n"
                    @"Host: 127.0.0.1:%d\r\n"
                    @"X-File-Name: %@\r\n"
                    @"Content-Length: %lu\r\n"
                    @"Connection: close\r\n\r\n",
                    port, firstURL.lastPathComponent ?: @"photo.jpg", (unsigned long)firstData.length];
                NSData *uHdrData = [uHdr dataUsingEncoding:NSUTF8StringEncoding];
                write(us, uHdrData.bytes, uHdrData.length);
                write(us, firstData.bytes, firstData.length);
                char uResp[256];
                ssize_t un = read(us, uResp, sizeof(uResp) - 1);
                close(us);
                if (un > 0 && strstr(uResp, "200 OK") != NULL) return YES;
            } else {
                close(us);
            }
        }
    }

    return NO;
}

// ── Main Entrypoint for File Sharing ──────────────────────────────────────────
- (NSString *)startWithFileURLs:(NSArray<NSURL *> *)fileURLs errorReason:(NSString **)outError {
    NSString *ip = [self localIPAddress];
    if (!ip) {
        if (outError) {
            *outError = @"No active Wi-Fi or Personal Hotspot connection detected.\n\nPlease turn on 'Personal Hotspot' in iPhone Settings (or connect both devices to the same Wi-Fi).";
        }
        return nil;
    }

    if (!fileURLs || fileURLs.count == 0) {
        if (outError) {
            *outError = @"Could not extract the selected photo or file.\n\nPlease ensure the photo is fully downloaded if stored in iCloud.";
        }
        return nil;
    }

    // Check if SpringBoard background server is listening on loopback (127.0.0.1)
    int bgPort = [self pingBackgroundServer];
    if (bgPort > 0) {
        BOOL registered = [self registerFilesWithBackgroundServer:fileURLs port:bgPort errorReason:outError];
        if (registered) {
            return [NSString stringWithFormat:@"http://%@:%d/", ip, bgPort];
        }
    }

    // If SpringBoard background server is not up (e.g. running in an unsandboxed app, or before respring):
    // Attempt local bind
    if (!_running) {
        _serverFd = socket(AF_INET, SOCK_STREAM, 0);
        if (_serverFd < 0) {
            if (outError) *outError = [NSString stringWithFormat:@"socket() failed (errno %d: %s)", errno, strerror(errno)];
            return nil;
        }

        int opt = 1;
        setsockopt(_serverFd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
#ifdef SO_REUSEPORT
        setsockopt(_serverFd, SOL_SOCKET, SO_REUSEPORT, &opt, sizeof(opt));
#endif

        int ports[] = {8765, 8766, 8888, 8080};
        BOOL bound = NO;
        int lastErr = 0;
        for (int i = 0; i < 4; i++) {
            int p = ports[i];
            struct sockaddr_in serv;
            memset(&serv, 0, sizeof(serv));
            serv.sin_family = AF_INET;
            serv.sin_addr.s_addr = INADDR_ANY;
            serv.sin_port = htons(p);

            if (bind(_serverFd, (struct sockaddr *)&serv, sizeof(serv)) == 0) {
                _boundPort = p;
                bound = YES;
                break;
            } else {
                lastErr = errno;
            }
        }

        if (!bound) {
            close(_serverFd);
            _serverFd = 0;
            if (lastErr == 1 /* EPERM */) {
                if (outError) {
                    *outError = @"Photos app is sandboxed by iOS.\n\nPlease respring your iPhone (restart SpringBoard) once to activate the unsandboxed BlueShare server, then try again.";
                }
            } else {
                if (outError) *outError = [NSString stringWithFormat:@"bind() failed (errno %d: %s)", lastErr, strerror(lastErr)];
            }
            return nil;
        }

        if (listen(_serverFd, 10) < 0) {
            int lErr = errno;
            close(_serverFd);
            _serverFd = 0;
            if (outError) *outError = [NSString stringWithFormat:@"listen() failed (errno %d: %s)", lErr, strerror(lErr)];
            return nil;
        }

        _running = YES;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self acceptLoop];
        });
    }

    // Set local file items
    @synchronized (self) {
        self->_fileItems = [NSMutableArray new];
        for (NSUInteger idx = 0; idx < fileURLs.count; idx++) {
            NSURL *u = fileURLs[idx];
            NSData *data = [NSData dataWithContentsOfURL:u];
            if (data && data.length > 0) {
                NSString *name = u.lastPathComponent ?: [NSString stringWithFormat:@"photo_%lu.jpg", (unsigned long)idx];
                NSString *mime = [self mimeTypeForExtension:name.pathExtension];
                [self->_fileItems addObject:@{
                    @"name": name,
                    @"mime": mime,
                    @"data": data,
                    @"index": @(idx)
                }];
            }
        }
    }

    if (self->_fileItems.count == 0) {
        if (outError) *outError = @"Could not read data from selected files.";
        return nil;
    }

    return [NSString stringWithFormat:@"http://%@:%d/", ip, _boundPort];
}

- (void)stop {
    // Only stop if running locally in this process
    NSString *bundleID = [NSBundle mainBundle].bundleIdentifier;
    if (![bundleID isEqualToString:@"com.apple.springboard"]) {
        _running = NO;
        if (_serverFd > 0) {
            close(_serverFd);
            _serverFd = 0;
        }
    }
}
@end

// ── DevicePickerViewController (Instant Share to Android) ─────────────────────
@interface DevicePickerViewController ()
@property (nonatomic, strong) NSArray<NSURL *> *fileURLs;
@property (nonatomic, strong) UIImageView      *qrImageView;
@property (nonatomic, strong) UILabel          *badgeLabel;
@property (nonatomic, strong) UILabel          *fileInfoLabel;
@property (nonatomic, strong) UILabel          *instructionLabel;
@property (nonatomic, copy)   NSString         *serverURL;
@end

@implementation DevicePickerViewController

- (instancetype)initWithFileURLs:(NSArray<NSURL *> *)fileURLs {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _fileURLs = [fileURLs copy];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Share to Android";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                             target:self action:@selector(didTapDone)];

    [self setupViews];
    [self startSharing];
}

- (void)setupViews {
    // Badge
    self.badgeLabel = [UILabel new];
    self.badgeLabel.textColor = [UIColor systemGreenColor];
    self.badgeLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    self.badgeLabel.backgroundColor = [[UIColor systemGreenColor] colorWithAlphaComponent:0.12];
    self.badgeLabel.layer.cornerRadius = 11;
    self.badgeLabel.layer.masksToBounds = YES;
    self.badgeLabel.textAlignment = NSTextAlignmentCenter;
    self.badgeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.badgeLabel];

    // Card background for QR
    UIView *qrCard = [UIView new];
    qrCard.backgroundColor = [UIColor whiteColor];
    qrCard.layer.cornerRadius = 20;
    qrCard.layer.shadowColor = [UIColor blackColor].CGColor;
    qrCard.layer.shadowOpacity = 0.08;
    qrCard.layer.shadowOffset = CGSizeMake(0, 8);
    qrCard.layer.shadowRadius = 16;
    qrCard.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:qrCard];

    // QR Image
    self.qrImageView = [UIImageView new];
    self.qrImageView.contentMode = UIViewContentModeScaleAspectFit;
    self.qrImageView.layer.magnificationFilter = kCAFilterNearest;
    self.qrImageView.translatesAutoresizingMaskIntoConstraints = NO;
    [qrCard addSubview:self.qrImageView];

    // File info
    self.fileInfoLabel = [UILabel new];
    self.fileInfoLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    self.fileInfoLabel.textColor = [UIColor labelColor];
    self.fileInfoLabel.textAlignment = NSTextAlignmentCenter;
    self.fileInfoLabel.numberOfLines = 2;
    self.fileInfoLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.fileInfoLabel];

    // Instructions
    self.instructionLabel = [UILabel new];
    self.instructionLabel.text = @"Point any Android Camera or Browser at this QR code.\nPhotos & videos save directly to Android Gallery!";
    self.instructionLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
    self.instructionLabel.textColor = [UIColor secondaryLabelColor];
    self.instructionLabel.textAlignment = NSTextAlignmentCenter;
    self.instructionLabel.numberOfLines = 0;
    self.instructionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.instructionLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.badgeLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.badgeLabel.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:20],
        [self.badgeLabel.heightAnchor constraintEqualToConstant:26],

        [qrCard.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [qrCard.topAnchor constraintEqualToAnchor:self.badgeLabel.bottomAnchor constant:20],
        [qrCard.widthAnchor constraintEqualToConstant:240],
        [qrCard.heightAnchor constraintEqualToConstant:240],

        [self.qrImageView.centerXAnchor constraintEqualToAnchor:qrCard.centerXAnchor],
        [self.qrImageView.centerYAnchor constraintEqualToAnchor:qrCard.centerYAnchor],
        [self.qrImageView.widthAnchor constraintEqualToConstant:210],
        [self.qrImageView.heightAnchor constraintEqualToConstant:210],

        [self.fileInfoLabel.topAnchor constraintEqualToAnchor:qrCard.bottomAnchor constant:24],
        [self.fileInfoLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [self.fileInfoLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],

        [self.instructionLabel.topAnchor constraintEqualToAnchor:self.fileInfoLabel.bottomAnchor constant:12],
        [self.instructionLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:28],
        [self.instructionLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-28],
    ]];
}

- (void)startSharing {
    NSString *ip = [[BSSimpleHTTPServer sharedServer] localIPAddress];
    if (!ip) {
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"Hotspot or Wi-Fi Required"
                             message:@"To transfer photos directly to Android without an app:\n\n1. Turn ON 'Personal Hotspot' in iPhone Settings (or connect both to Wi-Fi).\n2. Connect your Android phone to iPhone's Hotspot.\n3. Tap 'Try Again'!"
                      preferredStyle:UIAlertControllerStyleAlert];

        [alert addAction:[UIAlertAction actionWithTitle:@"Open Settings (Hotspot)"
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *_) {
            NSURL *url = [NSURL URLWithString:@"App-Prefs:root=INTERNET_TETHERING"];
            if (![[UIApplication sharedApplication] canOpenURL:url]) {
                url = [NSURL URLWithString:@"prefs:root=INTERNET_TETHERING"];
            }
            if (![[UIApplication sharedApplication] canOpenURL:url]) {
                url = [NSURL URLWithString:UIApplicationOpenSettingsURLString];
            }
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        }]];

        [alert addAction:[UIAlertAction actionWithTitle:@"Try Again"
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *_) {
            [self startSharing];
        }]];

        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                 style:UIAlertActionStyleCancel
                                               handler:^(UIAlertAction *_) {
            [self didTapDone];
        }]];

        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    NSString *errorReason = nil;
    NSString *url = [[BSSimpleHTTPServer sharedServer] startWithFileURLs:self.fileURLs errorReason:&errorReason];
    if (!url) {
        UIAlertController *err = [UIAlertController
            alertControllerWithTitle:@"Could Not Start Transfer"
                             message:errorReason ?: @"Please verify your Wi-Fi or Personal Hotspot connection and try again."
                      preferredStyle:UIAlertControllerStyleAlert];

        if ([errorReason containsString:@"respring"]) {
            [err addAction:[UIAlertAction actionWithTitle:@"Respring Now" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *_) {
                pid_t pid;
                const char *args[] = {"killall", "-9", "SpringBoard", NULL};
                posix_spawn(&pid, "/usr/bin/killall", NULL, NULL, (char *const *)args, environ);
            }]];
        }

        [err addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
            [self didTapDone];
        }]];
        [self presentViewController:err animated:YES completion:nil];
        return;
    }

    self.serverURL = url;
    NSString *conn = [[BSSimpleHTTPServer sharedServer] connectionType];
    self.badgeLabel.text = [NSString stringWithFormat:@"   ● Connected via %@   ", conn];

    if (self.fileURLs.count == 1) {
        NSURL *fileURL = self.fileURLs.firstObject;
        NSString *fileName = fileURL.lastPathComponent ?: @"File";
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:fileURL.path error:nil];
        unsigned long long fileSize = attrs.fileSize;
        if (fileSize > 0) {
            NSString *sizeStr = [NSByteCountFormatter stringFromByteCount:fileSize countStyle:NSByteCountFormatterCountStyleFile];
            self.fileInfoLabel.text = [NSString stringWithFormat:@"%@ (%@)", fileName, sizeStr];
        } else {
            self.fileInfoLabel.text = fileName;
        }
    } else {
        self.fileInfoLabel.text = [NSString stringWithFormat:@"Sharing %lu items", (unsigned long)self.fileURLs.count];
    }

    // Generate QR Code
    CIFilter *filter = [CIFilter filterWithName:@"CIQRCodeGenerator"];
    [filter setValue:[url dataUsingEncoding:NSUTF8StringEncoding] forKey:@"inputMessage"];
    [filter setValue:@"H" forKey:@"inputCorrectionLevel"];
    CIImage *ciImg = filter.outputImage;

    CIContext *ctx = [CIContext contextWithOptions:nil];
    CGImageRef cgImg = [ctx createCGImage:ciImg fromRect:ciImg.extent];
    UIImage *qr = [UIImage imageWithCGImage:cgImg scale:1.0 orientation:UIImageOrientationUp];
    if (cgImg) CGImageRelease(cgImg);
    self.qrImageView.image = qr;
}

- (void)didTapDone {
    [[BSSimpleHTTPServer sharedServer] stop];
    [self dismissViewControllerAnimated:YES completion:^{
        if (self.completionHandler) self.completionHandler(YES);
    }];
}

@end
