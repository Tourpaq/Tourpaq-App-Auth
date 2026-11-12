require "zlib"

# The Claude Desktop extension for the MCP Gateway (SPECS.md §25.8): a .mcpb file (a zip of manifest.json and a small
# Node.js bridge, claude_desktop_extension/bridge.js) that connects Claude Desktop to the gateway's /mcp endpoint.
# It holds no token: Claude Desktop asks for the person's tpa_mcp_… token when it is installed and keeps it in the
# system keychain (user_config, sensitive). So the file is the same for everyone and may be downloaded at any time.
#
#   ClaudeDesktopExtension.new(gateway).filename   # "tourpaq-mcp-gateway.mcpb"
#   ClaudeDesktopExtension.new(gateway).to_zip     # the file's bytes (the same bytes for the same gateway URL)
#   ClaudeDesktopExtension.claude_code_command(gateway, plain)  # the `claude mcp add` line for Claude Code
class ClaudeDesktopExtension
  # Raise when the bridge or the manifest changes, so Claude Desktop offers the update.
  VERSION = "1.0.0".freeze
  SERVER_NAME = "tourpaq".freeze
  BRIDGE = File.expand_path("claude_desktop_extension/bridge.js", __dir__)

  # The zip entries' modification time (MS-DOS format), fixed so the file is the same on every download.
  DOS_TIME = 0
  DOS_DATE = ((2026 - 1980) << 9) | (11 << 5) | 12

  attr_reader :gateway

  def initialize(gateway)
    raise ArgumentError, "#{gateway&.slug.inspect} is not a gateway app with a URL" unless gateway&.gateway? && gateway.url.present?
    @gateway = gateway
  end

  def self.endpoint(gateway) = "#{gateway.url.chomp('/')}/mcp"

  # Claude Code, for every project of the person (--scope user). The token is in it: shown once, like the token.
  def self.claude_code_command(gateway, plain_token)
    "claude mcp add --transport http --scope user #{SERVER_NAME} #{endpoint(gateway)} " \
      "--header \"Authorization: Bearer #{plain_token}\""
  end

  def endpoint = self.class.endpoint(gateway)
  def filename = "tourpaq-mcp-gateway.mcpb"

  def manifest
    {
      manifest_version: "0.2",
      name: "tourpaq-mcp-gateway",
      display_name: "Tourpaq MCP Gateway",
      version: VERSION,
      description: "Every Tourpaq MCP tool you have access to (logs, KPIs, offers, SQL replicas, Coolify, …), " \
                   "through the Tourpaq MCP Gateway with your personal token.",
      long_description: "Connects Claude Desktop to the Tourpaq MCP Gateway at #{endpoint}. You need NetBird and a " \
                        "personal MCP Gateway token (tpa_mcp_…) from the Tokens page of Tourpaq Auth; the tools you " \
                        "see follow your MCP access there, and every call is recorded with your name.",
      author: { name: "Tourpaq" },
      homepage: "#{AuthHosts.index_url.to_s.chomp('/')}/tokens",
      server: {
        type: "node",
        entry_point: "server/index.js",
        mcp_config: {
          command: "node",
          args: [ "${__dirname}/server/index.js" ],
          env: { "TOURPAQ_MCP_URL" => endpoint, "TOURPAQ_MCP_TOKEN" => "${user_config.token}" }
        }
      },
      user_config: {
        token: {
          type: "string",
          title: "MCP Gateway token",
          description: "Your personal token for the MCP Gateway (tpa_mcp_…), from the Tokens page of Tourpaq Auth.",
          sensitive: true,
          required: true
        }
      },
      compatibility: { platforms: %w[darwin win32 linux], runtimes: { node: ">=18.0.0" } },
      keywords: %w[tourpaq mcp gateway]
    }
  end

  def to_zip
    zip("manifest.json" => "#{JSON.pretty_generate(manifest)}\n", "server/index.js" => File.read(BRIDGE))
  end

  private

  # A zip with the entries stored (not compressed): the files are a few kilobytes, and Ruby has no zip writer without
  # a gem. UTF-8 names (flag bit 11), regular files with mode 0644.
  def zip(entries)
    out = "".b
    central = "".b
    entries.each do |name, content|
      name = name.b
      data = content.b
      crc = Zlib.crc32(data)
      offset = out.bytesize
      out << [ 0x04034b50, 20, 0x0800, 0, DOS_TIME, DOS_DATE, crc, data.bytesize, data.bytesize, name.bytesize, 0 ]
               .pack("VvvvvvVVVvv") << name << data
      central << [ 0x02014b50, 0x0314, 20, 0x0800, 0, DOS_TIME, DOS_DATE, crc, data.bytesize, data.bytesize,
                   name.bytesize, 0, 0, 0, 0, 0o100644 << 16, offset ].pack("VvvvvvvVVVvvvvvVV") << name
    end
    start = out.bytesize
    out << central
    out << [ 0x06054b50, 0, 0, entries.size, entries.size, central.bytesize, start, 0 ].pack("VvvvvVVv")
  end
end
