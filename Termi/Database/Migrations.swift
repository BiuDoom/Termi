import GRDB
import Foundation

enum Migrations {
    static func run(_ dbPool: DatabasePool) throws {
        try migrator.migrate(dbPool)
    }

    /// Every migration, in order (a test stops at an earlier one to upgrade from it).
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        // MARK: - v1: Core tables

        migrator.registerMigration("v1_core") { db in
            // groups (no FK deps)
            try db.create(table: "groups") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.column("created_at", .text).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }

            // tags (no FK deps)
            try db.create(table: "tags") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull().unique()
                t.column("color", .text).notNull().defaults(to: "#6366f1")
                t.column("created_at", .text).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }

            // ssh_keys (no FK deps — must be before hosts)
            try db.create(table: "ssh_keys") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("type", .text).notNull().defaults(to: "ed25519")
                t.column("public_key", .text).notNull()
                t.column("private_key_encrypted", .text).notNull()
                t.column("passphrase_encrypted", .text)
                t.column("fingerprint", .text)
                t.column("created_at", .text).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }

            // identities (depends on ssh_keys — must be before hosts)
            try db.create(table: "identities") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("username", .text).notNull()
                t.column("auth_type", .text).notNull().defaults(to: "password")
                t.column("password_encrypted", .text)
                t.column("private_key_id", .integer).references("ssh_keys", onDelete: .setNull)
                t.column("created_at", .text).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }

            // hosts (depends on ssh_keys, identities, groups)
            try db.create(table: "hosts") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("label", .text).notNull()
                t.column("hostname", .text).notNull()
                t.column("port", .integer).notNull().defaults(to: 22)
                t.column("username", .text).notNull().defaults(to: "root")
                t.column("auth_type", .text).notNull().defaults(to: "password")
                t.column("password_encrypted", .text)
                t.column("private_key_id", .integer).references("ssh_keys", onDelete: .setNull)
                t.column("identity_id", .integer).references("identities", onDelete: .setNull)
                t.column("group_id", .integer).references("groups", onDelete: .setNull)
                t.column("color", .text)
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.column("notes", .text)
                t.column("created_at", .text).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                t.column("updated_at", .text).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }

            // host_tags (depends on hosts, tags)
            try db.create(table: "host_tags") { t in
                t.column("host_id", .integer).notNull().references("hosts", onDelete: .cascade)
                t.column("tag_id", .integer).notNull().references("tags", onDelete: .cascade)
                t.primaryKey(["host_id", "tag_id"])
            }

            // known_hosts (no FK deps)
            try db.create(table: "known_hosts") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("hostname", .text).notNull()
                t.column("port", .integer).notNull().defaults(to: 22)
                t.column("key_type", .text).notNull()
                t.column("public_key", .text).notNull()
                t.column("fingerprint", .text).notNull()
                t.column("added_at", .text).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                t.uniqueKey(["hostname", "port", "key_type"])
            }

            // connection_logs
            try db.create(table: "connection_logs") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("host_id", .integer).references("hosts", onDelete: .cascade)
                t.column("host_label", .text).notNull()
                t.column("hostname", .text).notNull()
                t.column("status", .text).notNull()
                t.column("error_message", .text)
                t.column("duration_ms", .integer)
                t.column("connected_at", .text).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                t.column("disconnected_at", .text)
            }

            // settings
            try db.create(table: "settings") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull()
            }

            // vault
            try db.create(table: "vault") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("key", .text).notNull().unique()
                t.column("value_encrypted", .text).notNull()
                t.column("created_at", .text).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                t.column("updated_at", .text).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }

            // crypto_config
            try db.create(table: "crypto_config") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull()
            }
        }

        // MARK: - v2: Snippets + Port Forwards

        migrator.registerMigration("v2_snippets") { db in
            try db.create(table: "snippets") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("command", .text).notNull()
                t.column("description", .text)
                t.column("category", .text)
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.column("created_at", .text).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }

            try db.create(table: "port_forwards") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("host_id", .integer).notNull().references("hosts", onDelete: .cascade)
                t.column("type", .text).notNull().defaults(to: "local")
                t.column("local_port", .integer).notNull()
                t.column("remote_host", .text).notNull().defaults(to: "127.0.0.1")
                t.column("remote_port", .integer).notNull()
                t.column("enabled", .boolean).notNull().defaults(to: true)
                t.column("created_at", .text).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }
        }

        // MARK: - v3: Rate limiting

        migrator.registerMigration("v3_ratelimit") { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO crypto_config (key, value) VALUES ('failed_attempts', '0');
                INSERT OR IGNORE INTO crypto_config (key, value) VALUES ('locked_until', '0');
            """)
        }

        // MARK: - v4: Performance indices

        migrator.registerMigration("v4_indices") { db in
            // hosts FK columns — used in groupedFetch and filter queries
            try db.create(index: "idx_hosts_group_id", on: "hosts", columns: ["group_id"])
            try db.create(index: "idx_hosts_identity_id", on: "hosts", columns: ["identity_id"])
            try db.create(index: "idx_hosts_private_key_id", on: "hosts", columns: ["private_key_id"])

            // connection_logs — used in history/filter queries
            try db.create(index: "idx_logs_host_id", on: "connection_logs", columns: ["host_id"])
            try db.create(index: "idx_logs_connected_at", on: "connection_logs", columns: ["connected_at"])

            // snippets — used in category filter
            try db.create(index: "idx_snippets_category", on: "snippets", columns: ["category"])

            // identities FK
            try db.create(index: "idx_identities_key_id", on: "identities", columns: ["private_key_id"])
        }

        // MARK: - v5: X11 forwarding on hosts

        migrator.registerMigration("v5_x11") { db in
            try db.alter(table: "hosts") { t in
                t.add(column: "x11_forwarding", .boolean).notNull().defaults(to: false)
            }
        }

        // MARK: - v6: Termius-style host features

        migrator.registerMigration("v6_host_features") { db in
            try db.alter(table: "hosts") { t in
                // Jump host (host chaining). The jump host may itself use a jump host.
                t.add(column: "jump_host_id", .integer).references("hosts", onDelete: .setNull)
                t.add(column: "agent_forwarding", .boolean).notNull().defaults(to: false)
                // Snippet typed into the shell right after connecting.
                t.add(column: "startup_snippet_id", .integer).references("snippets", onDelete: .setNull)
                // Per-host terminal color theme (nil = app default).
                t.add(column: "terminal_theme", .text)
                t.add(column: "last_connected_at", .text)
            }
            // Group defaults inherited by member hosts that don't set their own.
            try db.alter(table: "groups") { t in
                t.add(column: "username", .text)
                t.add(column: "identity_id", .integer).references("identities", onDelete: .setNull)
                t.add(column: "jump_host_id", .integer).references("hosts", onDelete: .setNull)
            }
            try db.create(index: "idx_hosts_jump_host_id", on: "hosts", columns: ["jump_host_id"])
            try db.create(index: "idx_host_tags_tag_id", on: "host_tags", columns: ["tag_id"])
        }

        // MARK: - v7: repair key types

        // Keys imported before the type was read from the public key were all stored as "unknown".
        migrator.registerMigration("v7_key_types") { db in
            try db.execute(sql: """
                UPDATE ssh_keys SET type = CASE
                    WHEN public_key LIKE 'ssh-ed25519 %' OR public_key LIKE 'sk-ssh-ed25519@openssh.com %' THEN 'ed25519'
                    WHEN public_key LIKE 'ssh-rsa %' THEN 'rsa'
                    WHEN public_key LIKE 'ecdsa-sha2-%' OR public_key LIKE 'sk-ecdsa-sha2-%' THEN 'ecdsa'
                    WHEN public_key LIKE 'ssh-dss %' THEN 'dsa'
                    ELSE type END
                WHERE type = 'unknown'
                """)
        }

        // MARK: - v8: the system a host runs

        // Read from the host after it connects (HostSystemProbe); nil until then.
        migrator.registerMigration("v8_host_system") { db in
            try db.alter(table: "hosts") { t in
                t.add(column: "os_id", .text)
                t.add(column: "os_name", .text)
                t.add(column: "os_arch", .text)
                t.add(column: "os_detected_at", .text)
            }
        }

        // MARK: - v9: original ssh_config matching name

        migrator.registerMigration("v9_ssh_config_alias") { db in
            try db.alter(table: "hosts") { t in
                t.add(column: "ssh_config_alias", .text)
            }
        }

        return migrator
    }
}
