# DB Migration Strategy

> 문서 성격: 보조 참고 문서(Task Reference)
>
> Flyway/runtime migration 작업에서 읽는다.
> active canonical 문서와 충돌하면 active canonical 문서가 우선한다.
> 현재 schema 기준은 `docs/db/petnose_mvp_schema.dbml`과 `docs/db/V20260508__mvp_canonical_schema.sql`에서 확인한다.

## 목적

Flyway는 backend runtime의 database schema history를 관리한다. active product schema는 아래 canonical v2 문서에서 별도로 정의한다.

- `docs/PETNOSE_MVP_FINAL_PROJECT_SPEC.md`
- `docs/db/petnose_mvp_schema.dbml`
- `docs/db/V20260508__mvp_canonical_schema.sql`

`docs/db/` 아래의 SQL은 문서화된 clean schema다. application이 자동 적용하는 runtime migration file이 아니다.

## 현재 정책

- 이미 적용된 backend Flyway migration file은 수정하지 않는다.
- implementation work가 승인된 경우에만 새 backend migration을 추가한다.
- dev/prod runtime에서는 JPA DDL generation을 비활성화한다.
- clean dev DB rebuild는 local data를 버릴 수 있으므로 명시적 승인 뒤에만 수행한다.

## Backend Migration Directory

```text
backend/src/main/resources/db/migration/
```

Current runtime migrations:

- `V1__baseline.sql`: simplified MVP baseline tables.
- `V2__align_adoption_post_content_constraints.sql`: aligns `adoption_posts.title` with the 200-character API policy and makes `adoption_posts.content` `NOT NULL`.
- `V3__add_nose_verification_attempts.sql`: historical pre-refactor migration that added the auxiliary pre-post verification table.
- `V4__remove_nose_verification_attempts_and_align_verification_logs.sql`: removes the auxiliary table and aligns `verification_logs` with dog-centered verification history.
- `V5__add_multi_reference_nose_references.sql`: adds dog nose v2 multi-reference tracking through `dog_nose_references` and `verification_logs.score_breakdown_json`.
- `V6__add_user_profile_image_fields.sql`: adds optional `users.profile_image_*` metadata fields.
- `V7__add_password_reset_tokens.sql`: adds the auth support table for reset token hashes.
- `V8__add_adoption_post_likes.sql`: adds the `adoption_post_likes` relationship table.
- `V9__add_adoption_completion_adopter.sql`: adds `adoption_posts.adopter_user_id` and `adopted_at`.

V2 assumes existing `adoption_posts` rows were created through the current API/service policy. If a manually inserted legacy row has a title longer than 200 characters or null content, clean that data before applying V2.
V3 assumes the baseline `users`, `dogs`, `dog_images`, `verification_logs`, and `adoption_posts` tables already exist. V4 assumes V3 has run, then removes the old auxiliary attempt table. V5 through V9 align the runtime schema with the current develop submission table set: 7 core/relationship tables plus 1 auth support table. Historical attempt rows are not promoted because active adoption post creation is `dog_id` based.

Naming:

```text
V{version}__{description}.sql
```

Examples:

```text
V5__add_post_creation_audit.sql
V6__add_safe_operational_index.sql
```

## Environment Policy

| Environment | Flyway | JPA DDL | Notes |
|---|---|---|---|
| dev | enabled | `none` | Flyway owns DDL |
| test | usually disabled | test profile controlled | Tests may use in-memory or mocked persistence |
| prod | enabled | `none` | Direct production DDL is not allowed |

## Canonical v2 Alignment Strategy

code change가 승인된 경우 가장 안전한 alignment path는 아래 순서다.

1. `users`에 user profile field를 추가한다.
2. registration result snapshot read를 `verification_logs` 기준으로 이동한다.
3. dog nose v2 reference metadata를 `dog_nose_references`에 저장한다.
4. `password_reset_tokens`, `adoption_post_likes`, `adoption_posts.adopter_user_id`, `adopted_at`을 current develop scope로 반영한다.
5. removed dog snapshot column write를 중단한다.
6. data migration과 rollback review 뒤에만 removed column/table을 drop한다.
7. Qdrant point id는 UUID이며 `dogs.id`와 같지 않다. point id와 metadata는 `dog_nose_references`가 추적한다.

local dev에서만 canonical v2 clean schema로 clean rebuild하는 편이 빠를 수 있다. 단, destructive action이므로 명시적 승인이 필요하다.
