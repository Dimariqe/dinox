using Gee;
using Dino.Entities;

namespace Dino.Plugins.BotFeatures {

// Chat command handler for @BotFather-style interactive bot management.
// Users interact with the Botmother by sending commands in a self-chat.
public class BotfatherHandler : Object {

    private Dino.Application app;
    private BotRegistry registry;
    private TokenManager token_manager;
    private EjabberdApi? ejabberd_api;

    public BotfatherHandler(Dino.Application app, BotRegistry registry, TokenManager token_manager, EjabberdApi? ejabberd_api = null) {
        this.app = app;
        this.registry = registry;
        this.token_manager = token_manager;
        this.ejabberd_api = ejabberd_api;
    }

    // Validate bot ID + ownership. Returns null if invalid. (Clone removal)
    private BotInfo? require_owned_bot(string owner_jid, string id_str, out int bot_id) {
        bot_id = int.parse(id_str.strip());
        BotInfo? bot = registry.get_bot_by_id(bot_id);
        if (bot == null || bot.owner_jid != owner_jid) return null;
        return bot;
    }

    private static string bot_not_found(int bot_id) {
        return "❌ " + _("Bot #%d not found or does not belong to you.").printf(bot_id);
    }

    // Process a Botmother command from a user. Returns a response string.
    public string process_command(string owner_jid, string command_text) {
        string[] parts = command_text.strip().split(" ", 2);
        string cmd = parts[0].down();
        string? args = parts.length > 1 ? parts[1].strip() : null;

        switch (cmd) {
            case "/newbot":
                return cmd_newbot(owner_jid, args);
            case "/mybots":
                return cmd_mybots(owner_jid);
            case "/deletebot":
                return cmd_deletebot(owner_jid, args);
            case "/token":
                return cmd_token(owner_jid, args);
            case "/showtoken":
                return cmd_showtoken(owner_jid, args);
            case "/revoke":
                return cmd_revoke(owner_jid, args);
            case "/activate":
                return cmd_activate(owner_jid, args);
            case "/deactivate":
                return cmd_deactivate(owner_jid, args);
            case "/setcommands":
                return cmd_setcommands(owner_jid, args);
            case "/setdescription":
                return cmd_setdescription(owner_jid, args);
            case "/status":
                return cmd_status(owner_jid, args);
            case "/help":
            case "/start":
                return cmd_help(owner_jid);
            default:
                return _("Unknown command. Type /help for a list of available commands.");
        }
    }

    // /newbot <name> -- Create a new bot
    private string cmd_newbot(string owner_jid, string? name) {
        if (name == null || name.strip().length == 0) {
            return "➕ " + _("Create a new bot") + "\n\n" +
                _("Send the name for your bot:") + "\n" +
                "❯ /newbot MyBot";
        }

        string bot_name = name.strip();

        // Check max bots per user
        var existing = registry.get_bots_by_owner(owner_jid);
        if (existing.size >= 20) {
            return "⚠️ " + _("You already have 20 bots. Delete one first with /deletebot.");
        }

        // Create the bot
        string dummy_hash = "";
        int bot_id = registry.create_bot(bot_name, owner_jid, dummy_hash, "personal");

        // Generate token
        string raw_token = token_manager.generate_token(bot_id);

        registry.log_action(bot_id, "created", "owner=%s".printf(owner_jid));

        return "✅ " + _("Bot created!") + "\n\n" +
            "• " + _("Name: %s").printf(bot_name) + "\n" +
            "• ID: %d\n\n".printf(bot_id) +
            "🔑 " + _("Your API Token:") + "\n" +
            "──────────\n" +
            "%s\n".printf(raw_token) +
            "──────────\n\n" +
            "📋 " + _("Quick start:") + "\n" +
            "curl -H \"Authorization: Bearer %s\" \\\n".printf(raw_token) +
            "  http://localhost:7842/bot/getMe\n\n" +
            "⚠️ " + _("Save this token! It won't be shown again.") + "\n" +
            _("Regenerate: /token %d").printf(bot_id);
    }

    // /mybots -- List all bots owned by the user
    private string cmd_mybots(string owner_jid) {
        var bots = registry.get_bots_by_owner(owner_jid);
        if (bots.size == 0) {
            return "🤖 " + _("You don't have any bots yet.") + "\n\n" +
                _("Create your first bot:") + "\n" +
                "❯ /newbot MyBot";
        }

        var sb = new StringBuilder("🤖 " + _("Your Bots") + "\n");
        sb.append("───────────────\n");
        foreach (BotInfo bot in bots) {
            string status_icon = (bot.status == "active") ? "🟢" : "🔴";
            sb.append("%s #%d • %s\n".printf(status_icon, bot.id, bot.name ?? "?"));
            sb.append("   %s: %s • %s\n\n".printf(_("Mode"), bot.mode ?? "?", bot.status ?? "?"));
        }
        sb.append("───────────────\n");
        sb.append(_("Total: %d bot(s)").printf(bots.size));
        return sb.str;
    }

    // /deletebot <id> -- Delete a bot
    private string cmd_deletebot(string owner_jid, string? id_str) {
        if (id_str == null) {
            return "🗑️ " + _("Delete a bot") + "\n\n" +
                _("Usage:") + " /deletebot <ID>\n" +
                _("See your bots:") + " /mybots";
        }

        int bot_id;
        BotInfo? bot = require_owned_bot(owner_jid, id_str, out bot_id);
        if (bot == null) return bot_not_found(bot_id);

        string bot_name = bot.name ?? "?";

        // For dedicated bots: unregister from ejabberd
        if (bot.mode == "dedicated" && bot.jid != null && bot.jid.contains("@")) {
            string username = bot.jid.split("@")[0];
            if (ejabberd_api != null) {
                // BUG-22 fix: Await the result and log failures instead of fire-and-forget
                ejabberd_api.unregister_account.begin(username, (obj, res) => {
                    var result = ejabberd_api.unregister_account.end(res);
                    if (!result.success) {
                        warning("Botfather: Failed to unregister %s from ejabberd: %s - account may be orphaned",
                            username, result.error_message ?? "unknown");
                    } else {
                        message("Botfather: ejabberd unregister %s: OK", username);
                    }
                });
            } else {
                warning("Botfather: ejabberd API not available, cannot unregister %s", username);
            }
        }

        registry.delete_bot(bot_id);
        registry.log_action(bot_id, "deleted", "owner=%s".printf(owner_jid));

        return "✅ " + _("Bot '%s' (ID: %d) deleted.").printf(bot_name, bot_id) + "\n" +
            _("Token is now invalid.");
    }

    // /token <id> -- Regenerate token for a bot
    private string cmd_token(string owner_jid, string? id_str) {
        if (id_str == null) {
            return "🔑 " + _("Regenerate Token") + "\n\n" +
                _("Usage:") + " /token <ID>";
        }

        int bot_id;
        BotInfo? bot = require_owned_bot(owner_jid, id_str, out bot_id);
        if (bot == null) return bot_not_found(bot_id);

        string raw_token = token_manager.regenerate_token(bot_id);
        return "🔑 " + _("New Token for '%s'").printf(bot.name ?? "?") + "\n\n" +
            "──────────\n" +
            "%s\n".printf(raw_token) +
            "──────────\n\n" +
            "📋 " + _("Usage:") + "\n" +
            "curl -H \"Authorization: Bearer %s\" \\\n".printf(raw_token) +
            "  http://localhost:7842/bot/getMe\n\n" +
            "⚠️ " + _("The old token is now invalid.");
    }

    // /revoke <id> -- Revoke token without generating a new one
    private string cmd_revoke(string owner_jid, string? id_str) {
        if (id_str == null) {
            return "🚫 " + _("Revoke Token") + "\n\n" +
                _("Usage:") + " /revoke <ID>";
        }

        int bot_id;
        BotInfo? bot = require_owned_bot(owner_jid, id_str, out bot_id);
        if (bot == null) return bot_not_found(bot_id);

        token_manager.revoke_token(bot_id);
        registry.update_bot_status(bot_id, "disabled");

        return "🚫 " + _("Token revoked for '%s' (ID: %d)").printf(bot.name ?? "?", bot_id) + "\n\n" +
            "🔴 " + _("Bot is now disabled.") + "\n" +
            _("Generate a new token:") + " /token %d".printf(bot_id);
    }

    // /showtoken <id> -- Explain that tokens are not stored
    private string cmd_showtoken(string owner_jid, string? id_str) {
        if (id_str == null) {
            return "🔑 " + _("Show Token") + "\n\n" +
                _("Usage:") + " /showtoken <ID>";
        }

        int bot_id;
        BotInfo? bot = require_owned_bot(owner_jid, id_str, out bot_id);
        if (bot == null) return bot_not_found(bot_id);

        return "🔑 " + _("Token for '%s' (ID: %d)").printf(bot.name ?? "?", bot_id) + "\n\n" +
            "⚠️ " + _("Tokens are shown only once at creation and not stored.") + "\n\n" +
            _("Generate a new token:") + " /token %d".printf(bot_id);
    }

    // /activate <id> -- Activate a bot
    private string cmd_activate(string owner_jid, string? id_str) {
        if (id_str == null) {
            return "🟢 " + _("Activate Bot") + "\n\n" +
                _("Usage:") + " /activate <ID>\n" +
                _("See your bots:") + " /mybots";
        }

        int bot_id;
        BotInfo? bot = require_owned_bot(owner_jid, id_str, out bot_id);
        if (bot == null) return bot_not_found(bot_id);

        if (bot.status == "active") {
            return "🟢 " + _("Bot '%s' (ID: %d) is already active.").printf(bot.name ?? "?", bot_id);
        }

        registry.update_bot_status(bot_id, "active");
        registry.log_action(bot_id, "activated", "owner=%s".printf(owner_jid));

        return "✅ " + _("Bot '%s' (ID: %d) activated.").printf(bot.name ?? "?", bot_id) + "\n\n" +
            "🟢 " + _("The bot is now online and accepts API requests.");
    }

    // /deactivate <id> -- Deactivate a bot
    private string cmd_deactivate(string owner_jid, string? id_str) {
        if (id_str == null) {
            return "🔴 " + _("Deactivate Bot") + "\n\n" +
                _("Usage:") + " /deactivate <ID>\n" +
                _("See your bots:") + " /mybots";
        }

        int bot_id;
        BotInfo? bot = require_owned_bot(owner_jid, id_str, out bot_id);
        if (bot == null) return bot_not_found(bot_id);

        if (bot.status == "disabled" || bot.status == "inactive") {
            return "🔴 " + _("Bot '%s' (ID: %d) is already inactive.").printf(bot.name ?? "?", bot_id);
        }

        registry.update_bot_status(bot_id, "disabled");
        registry.log_action(bot_id, "deactivated", "owner=%s".printf(owner_jid));

        return "✅ " + _("Bot '%s' (ID: %d) deactivated.").printf(bot.name ?? "?", bot_id) + "\n\n" +
            "🔴 " + _("The bot is now offline. API requests will be rejected.") + "\n" +
            _("Reactivate:") + " /activate %d".printf(bot_id);
    }

    // /setcommands <id> /cmd1 - description, /cmd2 - description
    private string cmd_setcommands(string owner_jid, string? args) {
        if (args == null) {
            return "⚙️ " + _("Set Bot Commands") + "\n\n" +
                _("Usage:") + "\n" +
                "/setcommands <ID> /cmd1 - desc, /cmd2 - desc\n\n" +
                _("Example:") + "\n" +
                "/setcommands 1 /hello - Greet, /info - Bot info";
        }

        string[] tokens = args.strip().split(" ", 2);
        if (tokens.length < 2) {
            return "⚙️ " + _("Set Bot Commands") + "\n\n" +
                _("Usage:") + "\n" +
                "/setcommands <ID> /cmd1 - desc, /cmd2 - desc";
        }

        int bot_id;
        BotInfo? bot = require_owned_bot(owner_jid, tokens[0], out bot_id);
        if (bot == null) return bot_not_found(bot_id);

        string commands_str = tokens[1].strip();
        var commands = new ArrayList<CommandInfo>();

        foreach (string part in commands_str.split(",")) {
            string trimmed = part.strip();
            if (trimmed.length == 0) continue;

            string[] cmd_parts = trimmed.split("-", 2);
            string command = cmd_parts[0].strip();
            string? description = cmd_parts.length > 1 ? cmd_parts[1].strip() : null;
            if (command.has_prefix("/")) command = command.substring(1);
            commands.add(new CommandInfo(command, description));
        }

        if (commands.size == 0) {
            return "❌ " + _("No valid commands found.") + "\n" +
                _("Format: /cmd - description");
        }

        registry.set_bot_commands(bot_id, commands);
        return "✅ " + _("%d command(s) set for '%s'.").printf(commands.size, bot.name ?? "?");
    }

    // /setdescription <id> <text>
    private string cmd_setdescription(string owner_jid, string? args) {
        if (args == null) {
            return "📝 " + _("Set Bot Description") + "\n\n" +
                _("Usage:") + "\n" +
                "/setdescription <ID> <text>";
        }

        string[] tokens = args.strip().split(" ", 2);
        if (tokens.length < 2) {
            return "📝 " + _("Set Bot Description") + "\n\n" +
                _("Usage:") + "\n" +
                "/setdescription <ID> <text>";
        }

        int bot_id;
        BotInfo? bot = require_owned_bot(owner_jid, tokens[0], out bot_id);
        if (bot == null) return bot_not_found(bot_id);

        // Update description directly via SQL
        registry.bot.update()
            .with(registry.bot.id, "=", bot_id)
            .set(registry.bot.description, tokens[1].strip())
            .perform();

        return "✅ " + _("Description for '%s' updated.").printf(bot.name ?? "?");
    }

    // /status [id] -- Show bot status
    private string cmd_status(string owner_jid, string? id_str) {
        if (id_str == null) {
            // Show overall status
            var bots = registry.get_bots_by_owner(owner_jid);
            int active = 0;
            foreach (BotInfo b in bots) {
                if (b.status == "active") active++;
            }
            return "📊 " + _("Overview") + "\n" +
                "───────────────\n" +
                "• " + _("Bots: %d total, %d active").printf(bots.size, active) + "\n" +
                "• " + _("API: http://localhost:7842") + "\n" +
                "───────────────";
        }

        int bot_id;
        BotInfo? bot = require_owned_bot(owner_jid, id_str, out bot_id);
        if (bot == null) return bot_not_found(bot_id);

        string status_icon = (bot.status == "active") ? "🟢" : "🔴";

        var sb = new StringBuilder();
        sb.append("🤖 " + (bot.name ?? "?") + " #%d\n".printf(bot.id));
        sb.append("───────────────\n");
        sb.append("%s %s: %s\n".printf(status_icon, _("Status"), bot.status ?? "?"));
        sb.append("• %s: %s\n".printf(_("Mode"), bot.mode ?? "?"));
        sb.append("• %s: %s\n".printf(_("JID"), bot.jid ?? _("(personal)")));

        if (bot.webhook_enabled) {
            sb.append("• Webhook: %s\n".printf(bot.webhook_url ?? "?"));
        } else {
            sb.append("• Webhook: %s\n".printf(_("off")));
        }

        var cmds = registry.get_bot_commands(bot.id);
        if (cmds.size > 0) {
            sb.append("• %s: %d\n".printf(_("Commands"), cmds.size));
        }
        sb.append("───────────────");

        return sb.str;
    }

    // Build an xmpp: URI that auto-sends a command when clicked
    private string cmd_uri(string jid, string command) {
        string encoded = command.replace(" ", "%20");
        return "xmpp:" + jid + "?message;body=" + encoded;
    }

    // /help -- Show available commands
    private string cmd_help(string owner_jid) {
        return "🤖 Botmother\n" +
            "────────────────────\n\n" +

            "📦 " + _("Bot Management") + "\n" +
            "   " + cmd_uri(owner_jid, "/mybots") + " — " + _("List your bots") + "\n" +
            "   " + cmd_uri(owner_jid, "/status") + " — " + _("Show status") + "\n" +
            "   /newbot <Name>       — " + _("Create a new bot") + "\n" +
            "   /deletebot <ID>      — " + _("Delete a bot") + "\n" +
            "   /activate <ID>       — " + _("Activate a bot") + "\n" +
            "   /deactivate <ID>     — " + _("Deactivate a bot") + "\n\n" +

            "🔑 " + _("Token") + "\n" +
            "   /token <ID>          — " + _("Regenerate token") + "\n" +
            "   /showtoken <ID>      — " + _("Show current token") + "\n" +
            "   /revoke <ID>         — " + _("Revoke token") + "\n\n" +

            "⚙️ " + _("Settings") + "\n" +
            "   /setcommands <ID>    — " + _("Set bot commands") + "\n" +
            "   /setdescription <ID> — " + _("Set description") + "\n\n" +

            "────────────────────\n" +
            "🌐 HTTP API: http://localhost:7842\n\n" +

            "📋 " + _("Examples:") + "\n\n" +

            "① " + _("Get bot info (GET → JSON):") + "\n" +
            "──────────\n" +
            "curl -H \"Authorization: Bearer <TOKEN>\" \\\n" +
            "  http://localhost:7842/bot/getMe\n\n" +
            "→ " + _("Response:") + "\n" +
            "{\n" +
            "  \"ok\": true,\n" +
            "  \"result\": {\n" +
            "    \"id\": 1,\n" +
            "    \"name\": \"MyBot\",\n" +
            "    \"jid\": \"\",\n" +
            "    \"mode\": \"personal\",\n" +
            "    \"status\": \"active\",\n" +
            "    \"description\": \"\",\n" +
            "    \"created_at\": 1739478000\n" +
            "  }\n" +
            "}\n" +
            "──────────\n\n" +

            "② " + _("Send message (POST → JSON):") + "\n" +
            "──────────\n" +
            "curl -X POST \\\n" +
            "  -H \"Authorization: Bearer <TOKEN>\" \\\n" +
            "  -H \"Content-Type: application/json\" \\\n" +
            "  -d '{\n" +
            "    \"to\": \"user@server.tld\",\n" +
            "    \"text\": \"Hello!\"\n" +
            "  }' \\\n" +
            "  http://localhost:7842/bot/sendMessage\n\n" +
            "→ " + _("Response:") + "\n" +
            "{\n" +
            "  \"ok\": true,\n" +
            "  \"result\": {\n" +
            "    \"message_id\": \"abc-123\"\n" +
            "  }\n" +
            "}\n" +
            "──────────\n\n" +

            "💡 " + _("Notes:") + "\n" +
            "• " + _("Replace <TOKEN> with your bot token (/showtoken <ID>)") + "\n" +
            "• " + _("Header: Authorization: Bearer <TOKEN>") + "\n" +
            "• " + _("POST body field: \"text\" (not \"body\")") + "\n" +
            "• " + _("All responses: {\"ok\": true/false, \"result\": ...}");
    }
}

}
