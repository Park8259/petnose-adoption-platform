package com.petnose.api.domain.entity;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Collectors;

import static org.assertj.core.api.Assertions.assertThat;

class CanonicalSchemaConsistencyTest {

    private static final Set<String> ACTIVE_TABLES = Set.of(
            "users",
            "dogs",
            "dog_images",
            "dog_nose_references",
            "password_reset_tokens",
            "verification_logs",
            "adoption_posts"
    );
    private static final Set<String> USER_COLUMNS = Set.of(
            "id",
            "email",
            "password_hash",
            "role",
            "display_name",
            "contact_phone",
            "region",
            "profile_image_path",
            "profile_image_mime_type",
            "profile_image_file_size",
            "profile_image_sha256",
            "is_active",
            "created_at"
    );
    private static final Set<String> PASSWORD_RESET_TOKEN_COLUMNS = Set.of(
            "id",
            "user_id",
            "token_hash",
            "expires_at",
            "used_at",
            "created_at"
    );
    private static final Set<String> VERIFICATION_LOG_COLUMNS = Set.of(
            "id",
            "dog_id",
            "dog_image_id",
            "requested_by_user_id",
            "submitted_image_path",
            "submitted_image_mime_type",
            "submitted_image_file_size",
            "submitted_image_sha256",
            "result",
            "purpose",
            "similarity_score",
            "score_breakdown_json",
            "candidate_dog_id",
            "model",
            "dimension",
            "failure_reason",
            "created_at"
    );
    private static final Set<String> DOG_NOSE_REFERENCE_COLUMNS = Set.of(
            "id",
            "dog_id",
            "dog_image_id",
            "qdrant_point_id",
            "embedding_kind",
            "reference_index",
            "model",
            "dimension",
            "preprocess_version",
            "quality_status",
            "quality_score",
            "is_active",
            "created_at"
    );
    private static final List<String> RETIRED_PRECHECK_CONSUMPTION_FIELDS = List.of(
            "consumed_at",
            "consumed_by_post_id"
    );
    private static final Pattern CREATE_TABLE = Pattern.compile(
            "(?is)CREATE\\s+TABLE\\s+`?([a-z_]+)`?\\s*\\((.*?)\\)\\s*ENGINE\\s*="
    );
    private static final Pattern TABLE_COLUMN = Pattern.compile("^`?([a-z][a-z0-9_]*)`?\\s+");
    private static final Pattern INDEX_COLUMNS = Pattern.compile(
            "(?im)^\\s*(?:PRIMARY\\s+KEY|UNIQUE\\s+KEY\\s+`?[a-z0-9_]+`?|KEY\\s+`?[a-z0-9_]+`?|INDEX\\s+`?[a-z0-9_]+`?)\\s*\\(([^)]*)\\)"
    );
    private static final Pattern FOREIGN_KEY_COLUMNS = Pattern.compile("(?is)FOREIGN\\s+KEY\\s*\\(([^)]*)\\)");
    private static final Pattern CHECK_CONSTRAINT = Pattern.compile("(?is)CHECK\\s*\\((.*?)\\)");
    private static final Pattern CHECK_IDENTIFIER = Pattern.compile("(?i)\\b([a-z][a-z0-9_]*)\\b");
    private static final Pattern DBML_TABLE = Pattern.compile("(?im)^Table\\s+`?([a-z_]+)`?\\s*\\{");
    private static final Set<String> CHECK_KEYWORDS = Set.of(
            "and",
            "or",
            "not",
            "null",
            "is",
            "in",
            "true",
            "false"
    );

    @Test
    void activeCleanSqlCreatesExactlyCanonicalTables() throws Exception {
        String sql = canonicalSql();

        assertThat(tableDefinitions(sql).keySet()).containsExactlyInAnyOrderElementsOf(ACTIVE_TABLES);
        assertThat(sql).doesNotContain(removedAttemptTableName());
    }

    @Test
    void activeCleanSqlUsersIncludeProfileImageMetadata() throws Exception {
        String sql = canonicalSql();
        Map<String, Set<String>> columnsByTable = columnsByTable(sql);
        String users = tableDefinitions(sql).get("users");

        assertThat(columnsByTable.get("users"))
                .containsExactlyInAnyOrderElementsOf(USER_COLUMNS);
        assertThat(users).contains(
                "profile_image_path VARCHAR(500) NULL",
                "profile_image_mime_type VARCHAR(100) NULL",
                "profile_image_file_size BIGINT NULL",
                "profile_image_sha256 CHAR(64) NULL"
        );
    }

    @Test
    void activeCleanSqlVerificationLogsUseDogIdCenteredRuntimeColumns() throws Exception {
        String sql = canonicalSql();
        Map<String, Set<String>> columnsByTable = columnsByTable(sql);
        String verificationLogs = tableDefinitions(sql).get("verification_logs");

        assertThat(columnsByTable.get("verification_logs"))
                .containsExactlyInAnyOrderElementsOf(VERIFICATION_LOG_COLUMNS)
                .doesNotContain("expires_at")
                .doesNotContain(RETIRED_PRECHECK_CONSUMPTION_FIELDS.toArray(String[]::new));
        assertThat(verificationLogs).contains(
                "dog_image_id BIGINT NULL",
                "purpose VARCHAR(40) NOT NULL DEFAULT 'DOG_REGISTRATION'",
                "similarity_score DECIMAL(6, 5) NULL",
                "score_breakdown_json TEXT NULL"
        );
    }

    @Test
    void activeCleanSqlPasswordResetTokensStoreOnlyHashes() throws Exception {
        String sql = canonicalSql();
        Map<String, Set<String>> columnsByTable = columnsByTable(sql);
        String passwordResetTokens = tableDefinitions(sql).get("password_reset_tokens");

        assertThat(columnsByTable.get("password_reset_tokens"))
                .containsExactlyInAnyOrderElementsOf(PASSWORD_RESET_TOKEN_COLUMNS);
        assertThat(passwordResetTokens).contains(
                "token_hash CHAR(64) NOT NULL",
                "expires_at TIMESTAMP NOT NULL",
                "used_at TIMESTAMP NULL",
                "UNIQUE KEY uk_password_reset_tokens_hash (token_hash)",
                "KEY idx_password_reset_tokens_user_id (user_id)",
                "KEY idx_password_reset_tokens_expires_at (expires_at)",
                "KEY idx_password_reset_tokens_user_used (user_id, used_at)",
                "FOREIGN KEY (user_id) REFERENCES users (id)"
        );
        assertThat(passwordResetTokens).doesNotContain("reset_token VARCHAR", "reset_token TEXT", "raw_token", "plain_token");
    }

    @Test
    void activeCleanSqlDogNoseReferencesTrackQdrantPointsAndMetadata() throws Exception {
        String sql = canonicalSql();
        Map<String, Set<String>> columnsByTable = columnsByTable(sql);
        String dogNoseReferences = tableDefinitions(sql).get("dog_nose_references");

        assertThat(columnsByTable.get("dog_nose_references"))
                .containsExactlyInAnyOrderElementsOf(DOG_NOSE_REFERENCE_COLUMNS);
        assertThat(dogNoseReferences).contains(
                "qdrant_point_id CHAR(36) NOT NULL",
                "embedding_kind VARCHAR(20) NOT NULL",
                "preprocess_version VARCHAR(100) NOT NULL",
                "quality_status VARCHAR(30) NOT NULL DEFAULT 'ACCEPTED'",
                "UNIQUE KEY uk_dog_nose_references_qdrant_point_id (qdrant_point_id)",
                "KEY idx_dog_nose_references_dog_kind_active (dog_id, embedding_kind, is_active)",
                "FOREIGN KEY (dog_id) REFERENCES dogs (id)",
                "FOREIGN KEY (dog_image_id) REFERENCES dog_images (id)",
                "CHECK (embedding_kind IN ('REFERENCE', 'CENTROID'))",
                "CHECK (quality_status IN ('ACCEPTED', 'REJECTED', 'NEEDS_REVIEW'))"
        );
    }

    @Test
    void activeCleanSqlIndexesForeignKeysAndChecksReferenceDeclaredColumns() throws Exception {
        Map<String, String> tableBodies = tableDefinitions(canonicalSql());
        Map<String, Set<String>> columnsByTable = columnsByTable(tableBodies);

        tableBodies.forEach((tableName, body) -> {
            Set<String> declaredColumns = columnsByTable.get(tableName);
            assertReferencedColumnsExist(tableName, "index", body, INDEX_COLUMNS, declaredColumns);
            assertReferencedColumnsExist(tableName, "foreign key", body, FOREIGN_KEY_COLUMNS, declaredColumns);
            assertCheckColumnsExist(tableName, body, declaredColumns);
        });
    }

    @Test
    void activeDbmlMatchesCanonicalTableAndEnumScope() throws Exception {
        String dbml = canonicalDbml();

        assertThat(dbmlTableNames(dbml)).containsExactlyInAnyOrderElementsOf(ACTIVE_TABLES);
        assertThat(dbml).doesNotContain(removedAttemptTableName());
        assertThat(dbml).doesNotContain(RETIRED_PRECHECK_CONSUMPTION_FIELDS.toArray(String[]::new));
        assertThat(dbml).contains(
                "profile_image_path varchar(500)",
                "profile_image_mime_type varchar(100)",
                "profile_image_file_size bigint",
                "profile_image_sha256 char(64)",
                "Table password_reset_tokens",
                "token_hash char(64)",
                "expires_at timestamp",
                "used_at timestamp"
        );
        assertThat(dbmlEnumValues(dbml, "dog_status"))
                .containsExactly("PENDING", "REGISTERED", "DUPLICATE_SUSPECTED", "REVIEW_REQUIRED", "REJECTED", "ADOPTED", "INACTIVE");
        assertThat(dbmlEnumValues(dbml, "dog_image_type")).containsExactly("NOSE", "PROFILE");
        assertThat(dbmlEnumValues(dbml, "verification_result"))
                .containsExactly("PENDING", "PASSED", "DUPLICATE_SUSPECTED", "REVIEW_REQUIRED", "EMBED_FAILED", "QDRANT_SEARCH_FAILED", "QDRANT_UPSERT_FAILED");
        assertThat(dbmlEnumValues(dbml, "dog_nose_embedding_kind")).containsExactly("REFERENCE", "CENTROID");
        assertThat(dbmlEnumValues(dbml, "nose_reference_quality_status"))
                .containsExactly("ACCEPTED", "REJECTED", "NEEDS_REVIEW");
        assertThat(dbmlEnumValues(dbml, "verification_purpose"))
                .containsExactly("DOG_REGISTRATION", "HANDOVER_COMPARE");
    }

    private static void assertReferencedColumnsExist(
            String tableName,
            String referenceType,
            String body,
            Pattern pattern,
            Set<String> declaredColumns
    ) {
        Matcher matcher = pattern.matcher(body);
        while (matcher.find()) {
            for (String column : columnNames(matcher.group(1))) {
                assertThat(declaredColumns)
                        .as("%s %s references column %s", tableName, referenceType, column)
                        .contains(column);
            }
        }
    }

    private static void assertCheckColumnsExist(String tableName, String body, Set<String> declaredColumns) {
        Matcher matcher = CHECK_CONSTRAINT.matcher(body);
        while (matcher.find()) {
            String expression = matcher.group(1).replaceAll("'[^']*'", " ");
            Matcher identifierMatcher = CHECK_IDENTIFIER.matcher(expression);
            while (identifierMatcher.find()) {
                String identifier = identifierMatcher.group(1).toLowerCase();
                if (CHECK_KEYWORDS.contains(identifier)) {
                    continue;
                }
                assertThat(declaredColumns)
                        .as("%s check constraint references column %s", tableName, identifier)
                        .contains(identifier);
            }
        }
    }

    private static Map<String, Set<String>> columnsByTable(String sql) {
        return columnsByTable(tableDefinitions(sql));
    }

    private static Map<String, Set<String>> columnsByTable(Map<String, String> tableBodies) {
        Map<String, Set<String>> columnsByTable = new LinkedHashMap<>();
        tableBodies.forEach((tableName, body) -> columnsByTable.put(tableName, declaredColumns(body)));
        return columnsByTable;
    }

    private static Map<String, String> tableDefinitions(String sql) {
        Matcher matcher = CREATE_TABLE.matcher(sql);
        Map<String, String> definitions = new LinkedHashMap<>();
        while (matcher.find()) {
            definitions.put(matcher.group(1), matcher.group(2));
        }
        return definitions;
    }

    private static Set<String> declaredColumns(String tableBody) {
        return Arrays.stream(tableBody.split("\\R"))
                .map(CanonicalSchemaConsistencyTest::stripSqlLineComment)
                .map(String::trim)
                .filter(line -> !line.isEmpty())
                .filter(line -> !line.startsWith("PRIMARY "))
                .filter(line -> !line.startsWith("UNIQUE "))
                .filter(line -> !line.startsWith("KEY "))
                .filter(line -> !line.startsWith("INDEX "))
                .filter(line -> !line.startsWith("CONSTRAINT "))
                .map(CanonicalSchemaConsistencyTest::removeTrailingComma)
                .map(TABLE_COLUMN::matcher)
                .filter(Matcher::find)
                .map(matcher -> matcher.group(1))
                .collect(Collectors.toCollection(TreeSet::new));
    }

    private static List<String> columnNames(String columnList) {
        return Arrays.stream(columnList.split(","))
                .map(String::trim)
                .map(column -> column.replace("`", ""))
                .map(column -> column.replaceAll("(?i)\\s+(ASC|DESC)$", ""))
                .map(column -> column.replaceAll("\\(.+\\)$", ""))
                .filter(column -> !column.isEmpty())
                .toList();
    }

    private static Set<String> dbmlTableNames(String dbml) {
        Matcher matcher = DBML_TABLE.matcher(dbml);
        Set<String> tableNames = new TreeSet<>();
        while (matcher.find()) {
            tableNames.add(matcher.group(1));
        }
        return tableNames;
    }

    private static List<String> dbmlEnumValues(String dbml, String enumName) {
        Pattern enumPattern = Pattern.compile("(?is)Enum\\s+" + Pattern.quote(enumName) + "\\s*\\{(.*?)\\}");
        Matcher matcher = enumPattern.matcher(dbml);
        assertThat(matcher.find()).as("DBML enum %s", enumName).isTrue();
        return Arrays.stream(matcher.group(1).split("\\R"))
                .map(String::trim)
                .filter(line -> !line.isEmpty())
                .filter(line -> !line.startsWith("//"))
                .toList();
    }

    private static String stripSqlLineComment(String line) {
        int commentStart = line.indexOf("--");
        if (commentStart >= 0) {
            return line.substring(0, commentStart);
        }
        return line;
    }

    private static String removeTrailingComma(String line) {
        if (line.endsWith(",")) {
            return line.substring(0, line.length() - 1);
        }
        return line;
    }

    private static String removedAttemptTableName() {
        return "nose" + "_verification_attempts";
    }

    private static String canonicalSql() throws IOException {
        return repoFileText("docs/db/V20260508__mvp_canonical_schema.sql");
    }

    private static String canonicalDbml() throws IOException {
        return repoFileText("docs/db/petnose_mvp_schema.dbml");
    }

    private static String repoFileText(String relativePath) throws IOException {
        Path current = Path.of("").toAbsolutePath();
        for (Path root : List.of(current, current.getParent())) {
            if (root == null) {
                continue;
            }
            Path candidate = root.resolve(relativePath);
            if (Files.isRegularFile(candidate)) {
                return Files.readString(candidate, StandardCharsets.UTF_8);
            }
        }
        throw new IOException("Repository file not found: " + relativePath);
    }
}
