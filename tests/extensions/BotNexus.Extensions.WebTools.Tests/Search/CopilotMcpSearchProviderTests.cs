using System.Reflection;
using System.Text.Json;
using BotNexus.Extensions.Mcp;
using BotNexus.Extensions.Mcp.Protocol;
using BotNexus.Extensions.Mcp.Transport;
using BotNexus.Extensions.WebTools.Search;
using BotNexus.Extensions.WebTools.Tests.Helpers;

namespace BotNexus.Extensions.WebTools.Tests.Search;

[Trait("Category", "Unit")]
public class CopilotMcpSearchProviderTests
{
    [Fact]
    public async Task SearchAsync_InitializesClientCallsWebSearch_AndParsesJsonResults()
    {
        var handler = new MockHttpMessageHandler();
        handler.SetResponder((request, _) =>
        {
            if (request.Method == HttpMethod.Get)
            {
                return Task.FromResult(new HttpResponseMessage(System.Net.HttpStatusCode.OK)
                {
                    Content = new StringContent(string.Empty, System.Text.Encoding.UTF8, "text/event-stream")
                });
            }

            var method = ExtractJsonRpcMethod(request);
            return Task.FromResult(method switch
            {
                "initialize" => JsonRpcResult(new
                {
                    protocolVersion = "2024-11-05",
                    capabilities = new { tools = new { listChanged = false } },
                    serverInfo = new { name = "copilot", version = "1.0" }
                }),
                "notifications/initialized" => new HttpResponseMessage(System.Net.HttpStatusCode.OK),
                "tools/call" => JsonRpcResult(new
                {
                    content = new[]
                    {
                        new
                        {
                            type = "text",
                            text = """
                                   {"results":[{"title":"Doc","url":"https://example.com/doc","snippet":"From json"}]}
                                   """
                        }
                    },
                    isError = false
                }),
                _ => new HttpResponseMessage(System.Net.HttpStatusCode.BadRequest)
            });
        });

        await using var provider = new CopilotMcpSearchProvider(
            _ => Task.FromResult<string?>("copilot-token"),
            new HttpClient(handler),
            "https://unit.test/mcp");

        var results = await provider.SearchAsync("botnexus", 5, CancellationToken.None);

        results.ShouldHaveSingleItem();
        results[0].Title.ShouldBe("Doc");
        handler.Requests.Select(r => r.Body).Where(b => b is not null)
            .ShouldContain(body => body!.Contains("\"method\":\"initialize\""));
        handler.Requests.Select(r => r.Body).Where(b => b is not null)
            .ShouldContain(body => body!.Contains("\"method\":\"tools/call\""));
    }

    [Fact]
    public async Task SearchAsync_OAuthCredentialAndGet405_InitializesAndSearchesViaPost()
    {
        var handler = new MockHttpMessageHandler();
        var methods = new List<string>();
        handler.SetResponder(async (request, ct) =>
        {
            request.RequestUri.ShouldBe(new Uri("https://api.enterprise.githubcopilot.com/mcp"));
            request.Headers.Authorization?.Scheme.ShouldBe("Bearer");
            request.Headers.Authorization?.Parameter.ShouldBe("fake-github-oauth");
            if (request.Method == HttpMethod.Get)
            {
                methods.Add("GET");
                return new HttpResponseMessage(System.Net.HttpStatusCode.MethodNotAllowed);
            }
            request.Method.ShouldBe(HttpMethod.Post);
            var content = request.Content ?? throw new InvalidOperationException("Missing JSON-RPC request.");
            using var doc = JsonDocument.Parse(await content.ReadAsStringAsync(ct));
            var root = doc.RootElement;
            var method = root.GetProperty("method").GetString() ?? throw new InvalidOperationException("Missing method.");
            methods.Add(method);
            if (method == "notifications/initialized")
                return new HttpResponseMessage(System.Net.HttpStatusCode.Accepted);
            object result;
            if (method == "initialize")
            {
                result = new
                {
                    protocolVersion = "2024-11-05",
                    capabilities = new { tools = new { listChanged = false } },
                    serverInfo = new { name = "copilot", version = "1.0" }
                };
            }
            else
            {
                method.ShouldBe("tools/call");
                root.GetProperty("params").GetProperty("name").GetString().ShouldBe("web_search");
                result = new
                {
                    content = new[] { new { type = "text", text = "[Official docs](https://example.com/docs)" } },
                    isError = false
                };
            }
            return new HttpResponseMessage(System.Net.HttpStatusCode.OK)
            {
                Content = new StringContent(JsonSerializer.Serialize(new
                {
                    jsonrpc = "2.0", id = root.GetProperty("id").Clone(), result
                }), System.Text.Encoding.UTF8, "application/json")
            };
        });
        using var http = new HttpClient(handler);
        await using var provider = new CopilotMcpSearchProvider(
            _ => Task.FromResult<string?>("fake-github-oauth"), http,
            "https://api.enterprise.githubcopilot.com/mcp");

        var results = await provider.SearchAsync("docs", 5, CancellationToken.None);

        results.ShouldHaveSingleItem().Title.ShouldBe("Official docs");
        methods.ShouldBe(new[] { "GET", "initialize", "notifications/initialized", "tools/call" });
    }

    [Fact]
    public async Task SearchAsync_Get400IsNotAcceptedAsSuccessfulConnection()
    {
        var handler = new MockHttpMessageHandler();
        handler.EnqueueResponse(System.Net.HttpStatusCode.BadRequest, "Authorization header is badly formatted.");
        using var http = new HttpClient(handler);
        await using var provider = new CopilotMcpSearchProvider(
            _ => Task.FromResult<string?>("fake-session"), http);

        var ex = await Should.ThrowAsync<HttpRequestException>(async () =>
            await provider.SearchAsync("docs", 5, CancellationToken.None));

        ex.StatusCode.ShouldBe(System.Net.HttpStatusCode.BadRequest);
        handler.Requests.ShouldHaveSingleItem().Method.ShouldBe(HttpMethod.Get);
    }

    [Fact]
    public async Task SearchAsync_MissingOAuthCredentialMakesNoHttpRequests()
    {
        var handler = new MockHttpMessageHandler();
        using var http = new HttpClient(handler);
        await using var provider = new CopilotMcpSearchProvider(_ => Task.FromResult<string?>(null), http);

        _ = await Should.ThrowAsync<InvalidOperationException>(async () =>
            await provider.SearchAsync("docs", 5, CancellationToken.None));

        handler.Requests.ShouldBeEmpty();
    }

    [Fact]
    public async Task SearchAsync_WhenJsonParsingFails_FallsBackToMarkdownLinks()
    {
        var provider = new CopilotMcpSearchProvider(
            _ => Task.FromResult<string?>("token"),
            new HttpClient(new MockHttpMessageHandler()));
        SetClient(provider, await CreateInitializedClientAsync(new FakeMcpTransport
        {
            QueuedResponses =
                [
                    JsonResponse(2, new McpToolCallResult
                    {
                        Content =
                        [
                            new McpContent
                            {
                                Type = "text",
                                Text = "1. [Fallback](https://example.com/fallback)\nFrom markdown"
                            }
                        ],
                        IsError = false
                    })
                ]
        }));

        var results = await provider.SearchAsync("query", 5, CancellationToken.None);

        results.ShouldHaveSingleItem();
        results[0].Title.ShouldBe("Fallback");
        results[0].Url.ShouldBe("https://example.com/fallback");
    }

    [Fact]
    public async Task SearchAsync_WhenInitializationFails_ThrowsClearError()
    {
        await using var provider = new CopilotMcpSearchProvider(
            _ => Task.FromResult<string?>(null),
            new HttpClient(new MockHttpMessageHandler()));

        var act = () => provider.SearchAsync("query", 5, CancellationToken.None);

        (await act.ShouldThrowAsync<InvalidOperationException>())
            .Message.ShouldContain("Copilot token unavailable");
    }

    [Fact]
    public async Task SearchAsync_WhenToolCallReturnsError_ThrowsClearError()
    {
        var provider = new CopilotMcpSearchProvider(
            _ => Task.FromResult<string?>("token"),
            new HttpClient(new MockHttpMessageHandler()));
        SetClient(provider, await CreateInitializedClientAsync(new FakeMcpTransport
        {
            QueuedResponses =
                [
                    JsonResponse(2, new McpToolCallResult
                    {
                        Content = [new McpContent { Type = "text", Text = "upstream failed" }],
                        IsError = true
                    })
                ]
        }));

        var act = () => provider.SearchAsync("query", 5, CancellationToken.None);

        var ex = await act.ShouldThrowAsync<InvalidOperationException>();
        ex.Message.ShouldContain("returned an error");
        ex.Message.ShouldContain("upstream failed");
    }

    [Fact]
    public async Task SearchAsync_WithConcurrentCalls_UsesSingleMcpClient()
    {
        var transport = new FakeMcpTransport
        {
            QueuedResponses = [.. Enumerable.Range(0, 10).Select(i => JsonResponse(i + 2, new McpToolCallResult
            {
                Content = [new McpContent { Type = "text", Text = $"[{i}](https://example.com/{i})" }],
                IsError = false
            }))]
        };
        var provider = new CopilotMcpSearchProvider(
            _ => Task.FromResult<string?>("token"),
            new HttpClient(new MockHttpMessageHandler()));
        SetClient(provider, await CreateInitializedClientAsync(transport));

        var tasks = Enumerable.Range(0, 10)
            .Select(_ => provider.SearchAsync("query", 1, CancellationToken.None))
            .ToArray();

        var results = await Task.WhenAll(tasks);

        results.Count().ShouldBe(10);
        transport.ConnectCallCount.ShouldBe(1);
    }

    [Fact]
    public async Task DisposeAsync_DisposesMcpClient()
    {
        var transport = new FakeMcpTransport();
        var provider = new CopilotMcpSearchProvider(
            _ => Task.FromResult<string?>("token"),
            new HttpClient(new MockHttpMessageHandler()));
        SetClient(provider, await CreateInitializedClientAsync(transport));

        await provider.DisposeAsync();

        transport.DisconnectCallCount.ShouldBe(1);
        transport.DisposeCallCount.ShouldBe(1);
    }

    private static HttpResponseMessage JsonRpcResult<T>(T result)
    {
        var responseJson = JsonSerializer.Serialize(new
        {
            jsonrpc = "2.0",
            id = 1,
            result
        });

        return new HttpResponseMessage(System.Net.HttpStatusCode.OK)
        {
            Content = new StringContent(responseJson, System.Text.Encoding.UTF8, "application/json")
        };
    }

    private static string? ExtractJsonRpcMethod(HttpRequestMessage request)
    {
        if (request.Content is null) return null;
        var body = request.Content.ReadAsStringAsync().GetAwaiter().GetResult();
        if (string.IsNullOrWhiteSpace(body)) return null;
        using var doc = JsonDocument.Parse(body);
        return doc.RootElement.TryGetProperty("method", out var method)
            ? method.GetString()
            : null;
    }

    private static async Task<McpClient> CreateInitializedClientAsync(FakeMcpTransport transport)
    {
        transport.QueuedResponses =
        [
            JsonResponse(1, new McpInitializeResult
            {
                ProtocolVersion = "2024-11-05",
                Capabilities = new McpServerCapabilities
                {
                    Tools = new McpToolCapability { ListChanged = false }
                },
                ServerInfo = new McpServerInfo { Name = "fake", Version = "1.0" }
            }),
            .. transport.QueuedResponses
        ];

        var client = new McpClient(transport, "copilot");
        await client.InitializeAsync();
        return client;
    }

    private static JsonRpcResponse JsonResponse<T>(object id, T result) =>
        new()
        {
            Id = id,
            Result = JsonSerializer.SerializeToElement(result)
        };

    private static void SetClient(CopilotMcpSearchProvider provider, McpClient client)
    {
        typeof(CopilotMcpSearchProvider)
            .GetField("_client", BindingFlags.Instance | BindingFlags.NonPublic)!
            .SetValue(provider, client);
    }

    private sealed class FakeMcpTransport : IMcpTransport
    {
        private readonly Queue<JsonRpcResponse> _queue = new();
        private bool _connected;

        public List<JsonRpcRequest> SentRequests { get; } = [];
        public List<JsonRpcNotification> SentNotifications { get; } = [];
        public List<JsonRpcResponse> QueuedResponses
        {
            get => [.. _queue];
            set
            {
                _queue.Clear();
                foreach (var item in value)
                    _queue.Enqueue(item);
            }
        }

        public int ConnectCallCount { get; private set; }
        public int DisconnectCallCount { get; private set; }
        public int DisposeCallCount { get; private set; }

        public Task ConnectAsync(CancellationToken ct = default)
        {
            ConnectCallCount++;
            _connected = true;
            return Task.CompletedTask;
        }

        public Task SendAsync(JsonRpcRequest message, CancellationToken ct = default)
        {
            if (!_connected)
                throw new InvalidOperationException("Not connected");

            SentRequests.Add(message);
            return Task.CompletedTask;
        }

        public Task SendNotificationAsync(JsonRpcNotification message, CancellationToken ct = default)
        {
            SentNotifications.Add(message);
            return Task.CompletedTask;
        }

        public Task<JsonRpcResponse> ReceiveAsync(CancellationToken ct = default)
        {
            if (_queue.Count == 0)
                throw new InvalidOperationException("No queued response");

            return Task.FromResult(_queue.Dequeue());
        }

        public Task DisconnectAsync(CancellationToken ct = default)
        {
            DisconnectCallCount++;
            _connected = false;
            return Task.CompletedTask;
        }

        public ValueTask DisposeAsync()
        {
            DisposeCallCount++;
            return ValueTask.CompletedTask;
        }
    }
}
