/*
 * Copyright (C) 2014 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "config.h"
#import <WebKit/WKFoundation.h>

#import "PlatformUtilities.h"
#import "TCPServer.h"
#import "Test.h"
#import "TestNavigationDelegate.h"
#import "TestWKWebView.h"
#import <WebKit/WKContentWorld.h>
#import <WebKit/WKErrorPrivate.h>
#import <WebKit/WKWebViewPrivate.h>
#import <wtf/RetainPtr.h>

static bool isDone;

TEST(WKWebView, EvaluateJavaScriptBlockCrash)
{
    @autoreleasepool {
        RetainPtr<WKWebView> webView = adoptNS([[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)]);

        NSURLRequest *request = [NSURLRequest requestWithURL:[[NSBundle mainBundle] URLForResource:@"simple" withExtension:@"html" subdirectory:@"TestWebKitAPI.resources"]];
        [webView loadRequest:request];

        [webView evaluateJavaScript:@"" completionHandler:^(id result, NSError *error) {
            // NOTE: By referencing the request here, we convert the block into a stack block rather than a global block and thus allow the copying of the block
            // in evaluateJavaScript to be meaningful.
            (void)request;
            
            EXPECT_NULL(result);
            EXPECT_NOT_NULL(error);

            isDone = true;
        }];

        // Force the WKWebView to be destroyed to allow evaluateJavaScript's completion handler to be called with an error.
        webView = nullptr;
    }

    isDone = false;
    TestWebKitAPI::Util::run(&isDone);
}

TEST(WKWebView, EvaluateJavaScriptErrorCases)
{
    RetainPtr<WKWebView> webView = adoptNS([[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)]);

    NSURLRequest *request = [NSURLRequest requestWithURL:[[NSBundle mainBundle] URLForResource:@"simple" withExtension:@"html" subdirectory:@"TestWebKitAPI.resources"]];
    [webView loadRequest:request];
    [webView _test_waitForDidFinishNavigation];

    [webView evaluateJavaScript:@"document.body" completionHandler:^(id result, NSError *error) {
        EXPECT_NULL(result);
        EXPECT_WK_STREQ(@"WKErrorDomain", [error domain]);
        EXPECT_EQ(WKErrorJavaScriptResultTypeIsUnsupported, [error code]);

        isDone = true;
    }];

    isDone = false;
    TestWebKitAPI::Util::run(&isDone);

    [webView evaluateJavaScript:@"document.body.insertBefore(document, document)" completionHandler:^(id result, NSError *error) {
        EXPECT_NULL(result);
        EXPECT_WK_STREQ(@"WKErrorDomain", [error domain]);
        EXPECT_EQ(WKErrorJavaScriptExceptionOccurred, [error code]);
        EXPECT_NOT_NULL([error.userInfo objectForKey:_WKJavaScriptExceptionMessageErrorKey]);
        EXPECT_GT([[error.userInfo objectForKey:_WKJavaScriptExceptionMessageErrorKey] length], (unsigned long)0);
        EXPECT_EQ(1, [[error.userInfo objectForKey:_WKJavaScriptExceptionLineNumberErrorKey] intValue]);
        EXPECT_EQ(27, [[error.userInfo objectForKey:_WKJavaScriptExceptionColumnNumberErrorKey] intValue]);

        isDone = true;
    }];

    isDone = false;
    TestWebKitAPI::Util::run(&isDone);

    [webView evaluateJavaScript:@"\n\nthrow 'something bad'" completionHandler:^(id result, NSError *error) {
        EXPECT_NULL(result);
        EXPECT_WK_STREQ(@"WKErrorDomain", [error domain]);
        EXPECT_EQ(WKErrorJavaScriptExceptionOccurred, [error code]);
        EXPECT_WK_STREQ(@"something bad", [error.userInfo objectForKey:_WKJavaScriptExceptionMessageErrorKey]);
        EXPECT_EQ(3, [[error.userInfo objectForKey:_WKJavaScriptExceptionLineNumberErrorKey] intValue]);
        EXPECT_EQ(22, [[error.userInfo objectForKey:_WKJavaScriptExceptionColumnNumberErrorKey] intValue]);
        EXPECT_NOT_NULL([error.userInfo objectForKey:_WKJavaScriptExceptionSourceURLErrorKey]);

        isDone = true;
    }];

    isDone = false;
    TestWebKitAPI::Util::run(&isDone);
}

TEST(WKWebView, WKContentWorld)
{
    EXPECT_NULL(WKContentWorld.pageWorld.name);
    EXPECT_NULL(WKContentWorld.defaultClientWorld.name);
    EXPECT_FALSE(WKContentWorld.pageWorld == WKContentWorld.defaultClientWorld);

    WKContentWorld *namedWorld = [WKContentWorld worldWithName:@"Name"];
    EXPECT_TRUE([namedWorld.name isEqualToString:@"Name"]);
    EXPECT_EQ(namedWorld, [WKContentWorld worldWithName:@"Name"]);
}

TEST(WKWebView, EvaluateJavaScriptInWorlds)
{
    RetainPtr<TestWKWebView> webView = adoptNS([[TestWKWebView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)]);
    [webView synchronouslyLoadHTMLString:@"<html></html>"];

    // Set a variable in the main world via "normal" evaluateJavaScript
    isDone = false;
    [webView evaluateJavaScript:@"var foo = 'bar'" completionHandler:^(id result, NSError *error) {
        isDone = true;
    }];
    isDone = false;

    // Verify that value is visible when evaluating in the pageWorld
    [webView evaluateJavaScript:@"foo" inContentWorld:WKContentWorld.pageWorld completionHandler:^(id result, NSError *error) {
        EXPECT_TRUE([result isKindOfClass:[NSString class]]);
        EXPECT_TRUE([result isEqualToString:@"bar"]);
        isDone = true;
    }];
    isDone = false;

    // Verify that value is not visible when evaluating in the defaultClientWorld
    [webView evaluateJavaScript:@"foo" inContentWorld:WKContentWorld.defaultClientWorld completionHandler:^(id result, NSError *error) {
        EXPECT_NULL(result);
        isDone = true;
    }];
    isDone = false;

    // Verify that value is visible when calling a function in the pageWorld
    [webView callAsyncJavaScript:@"return foo" arguments:nil inContentWorld:WKContentWorld.pageWorld completionHandler:[&] (id result, NSError *error) {
        EXPECT_TRUE([result isKindOfClass:[NSString class]]);
        EXPECT_TRUE([result isEqualToString:@"bar"]);
        isDone = true;
    }];
    isDone = false;

    // Verify that value is not visible when calling a function in the defaultClientWorld
    [webView callAsyncJavaScript:@"return foo" arguments:nil inContentWorld:WKContentWorld.defaultClientWorld completionHandler:[&] (id result, NSError *error) {
        EXPECT_NULL(result);
        isDone = true;
    }];
    isDone = false;

    // Set a varibale value in a named world.
    RetainPtr<WKContentWorld> namedWorld = [WKContentWorld worldWithName:@"NamedWorld"];
    [webView evaluateJavaScript:@"var bar = baz" inContentWorld:namedWorld.get() completionHandler:^(id result, NSError *error) {
        EXPECT_NULL(result);
        isDone = true;
    }];
    isDone = false;

    // Set a global varibale value in a named world via a function call.
    [webView callAsyncJavaScript:@"window.baz = bat" arguments:nil inContentWorld:namedWorld.get() completionHandler:^(id result, NSError *error) {
        EXPECT_NULL(result);
        EXPECT_NULL(error);
        isDone = true;
    }];
    isDone = false;

    // Verify they are there in that named world.
    [webView evaluateJavaScript:@"bar" inContentWorld:namedWorld.get() completionHandler:^(id result, NSError *error) {
        EXPECT_TRUE([result isKindOfClass:[NSString class]]);
        EXPECT_TRUE([result isEqualToString:@"baz"]);
        isDone = true;
    }];
    isDone = false;

    [webView evaluateJavaScript:@"window.baz" inContentWorld:namedWorld.get() completionHandler:^(id result, NSError *error) {
        EXPECT_TRUE([result isKindOfClass:[NSString class]]);
        EXPECT_TRUE([result isEqualToString:@"bat"]);
        isDone = true;
    }];
    isDone = false;

    // Verify they aren't there in the defaultClientWorld.
    [webView evaluateJavaScript:@"bar" inContentWorld:WKContentWorld.defaultClientWorld completionHandler:^(id result, NSError *error) {
        EXPECT_NULL(result);
        isDone = true;
    }];
    isDone = false;

    [webView evaluateJavaScript:@"window.baz" inContentWorld:WKContentWorld.defaultClientWorld completionHandler:^(id result, NSError *error) {
        EXPECT_NULL(result);
        isDone = true;
    }];
    isDone = false;

    // Verify they aren't there in the pageWorld.
    [webView evaluateJavaScript:@"bar" inContentWorld:WKContentWorld.pageWorld completionHandler:^(id result, NSError *error) {
        EXPECT_NULL(result);
        isDone = true;
    }];
    isDone = false;

    [webView evaluateJavaScript:@"window.baz" inContentWorld:WKContentWorld.pageWorld completionHandler:^(id result, NSError *error) {
        EXPECT_NULL(result);
        isDone = true;
    }];
    isDone = false;
}

TEST(WebKit, EvaluateJavaScriptInAttachments)
{
    // Attachments displayed inline are in sandboxed documents.
    // Evaluating JavaScript in such a document should fail and result in an error.

    using namespace TestWebKitAPI;
    TCPServer server([](int socket) {
        NSString *response = @"HTTP/1.1 200 OK\r\n"
            "Content-Length: 12\r\n"
            "Content-Disposition: attachment; filename=fromHeader.txt;\r\n\r\n"
            "Hello world!";

        TCPServer::read(socket);
        TCPServer::write(socket, response.UTF8String, response.length);
    });
    auto webView = adoptNS([TestWKWebView new]);
    [webView synchronouslyLoadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%d/", server.port()]]]];

    __block bool done = false;
    [webView evaluateJavaScript:@"Hello" completionHandler:^(id result, NSError *error) {
        EXPECT_NULL(result);
        EXPECT_NOT_NULL(error);
        EXPECT_TRUE([[error description] containsString:@"Cannot execute JavaScript in this document"]);
        done = true;
    }];
    TestWebKitAPI::Util::run(&done);
}

