# Google API Improvement Proposals (AIP) Compliance

This document tracks compliance with Google's API Improvement Proposals (AIPs) for the MacosUseSDK. All proto definitions MUST follow these standards.

## Core AIPs

### AIP-121: Resource-Oriented Design
**Status**: 🔴 VIOLATIONS EXIST

**Requirements**:
- Resources are nouns, methods are verbs
- Every resource MUST support Get and List (except singletons)
- Use standard methods (Get, List, Create, Update, Delete) over custom methods
- Resource schema MUST be consistent across all methods

**Current Violations**:
- All proto files use resource-oriented design ✅
- Need to verify resource schema consistency across methods

### AIP-122: Resource Names
**Status**: 🔴 VIOLATIONS EXIST

**Requirements**:
- Resource MUST have `string name` field as first field
- Name field MUST be annotated with `(google.api.field_behavior) = IDENTIFIER`
- Name field format: `collection/{id}/subcollection/{id}`
- Collection identifiers MUST be plural camelCase
- Resource IDs MUST follow RFC-1034 (lowercase letters, numbers, hyphens)
- NO embedding of resource messages in other resources

**Current Violations**:
- Window, Application, Element resources have proper name fields ✅
- Need to verify IDENTIFIER annotation on all name fields

### AIP-123: Resource Types
**Status**: 🔴 VIOLATIONS EXIST

**Requirements**:
- MUST use `google.api.resource` annotation with:
  - `type`: fully qualified (e.g., "macosusesdk.googleapis.com/Window")
  - `pattern`: resource name pattern
  - `singular`: singular form
  - `plural`: plural form
- Pattern variables use snake_case
- Type MUST be unique within pattern

**Current Violations**:
- Need to add/verify resource annotations on Window, Application, Element, Observation, Session, Macro, Script

### AIP-131: Standard Get Method
**Status**: 🔴 CRITICAL VIOLATIONS

**Requirements**:
- Method name: `Get{Resource}` (singular form)
- Request: `Get{Resource}Request`
- Response: Resource itself (NO `Get{Resource}Response`)
- Request MUST have `string name` field (NOT `parent` + `id`)
- `name` field MUST be annotated as REQUIRED
- `name` field MUST have resource_reference annotation
- HTTP verb: GET
- URI: `/v1/{name=collection/*/resource/*}`
- method_signature: `"name"`

**Current Violations**:
- ❌ GetElement uses `parent` + `element_id` instead of `name` field (14 warnings)
- ❌ GetElementActions same issue
- ❌ GetSession needs `name` field not separate fields
- ❌ GetSessionSnapshot needs `name` field
- ❌ GetClipboard needs `name` field
- ❌ GetClipboardHistory needs `name` field
- ❌ GetMetrics needs `name` field
- ❌ GetPerformanceReport needs `name` field
- ❌ GetScriptingDictionaries needs `name` field

**FIX PATTERN**:
```proto
// WRONG:
message GetElementRequest {
  string parent = 1;  // ❌
  string element_id = 2;  // ❌
}

// CORRECT:
message GetElementRequest {
  // The name of the element to retrieve.
  // Format: applications/{application}/elements/{element}
  string name = 1 [
    (google.api.field_behavior) = REQUIRED,
    (google.api.resource_reference) = {
      type: "macosusesdk.googleapis.com/Element"
    }
  ];
}
```

### AIP-132: Standard List Method
**Status**: ⚠️ NEEDS VERIFICATION

**Requirements**:
- Method name: `List{Resources}` (plural form)
- Request: `List{Resources}Request`, Response: `List{Resources}Response`
- Request MUST have `string parent` field (for non-top-level resources)
- MUST support pagination: `int32 page_size`, `string page_token`
- Response MUST have `repeated {Resource}` and `string next_page_token`
- HTTP verb: GET
- URI: `/v1/{parent=collection/*}/resources`
- method_signature: `"parent"`

**Current Status**:
- ListWindows, ListApplications, ListElements implemented ✅
- Need to verify pagination fields exist
- Need to verify parent field has resource_reference annotation

### AIP-133: Standard Create Method
**Status**: ⚠️ NEEDS VERIFICATION

**Requirements**:
- Method name: `Create{Resource}` (singular form)
- Request: `Create{Resource}Request`, Response: Resource itself
- Request MUST have `string parent` field
- Request MUST have resource field (e.g., `Book book`)
- Request MUST have `string {resource}_id` field for management plane
- HTTP verb: POST
- URI: `/v1/{parent=collection/*}/resources`
- Body: resource field
- method_signature: `"parent,{resource},{resource}_id"`

**Current Status**:
- CreateMacro, CreateObservation, CreateSession exist ✅
- Need to verify parent fields have resource_reference
- Need to verify {resource}_id fields exist

### AIP-134: Standard Update Method
**Status**: ⚠️ NEEDS VERIFICATION

**Requirements**:
- Method name: `Update{Resource}` (singular form)
- Request: `Update{Resource}Request`, Response: Resource itself
- Request MUST have resource field
- Request MUST have `google.protobuf.FieldMask update_mask` field
- update_mask MUST be OPTIONAL behavior
- HTTP verb: PATCH
- URI: `/v1/{resource.name=collection/*/resource/*}`
- Body: resource field
- method_signature: `"{resource},update_mask"`

**Current Status**:
- UpdateMacro, UpdateObservation, UpdateSession exist ✅
- Need to verify update_mask field exists and is OPTIONAL

### AIP-135: Standard Delete Method
**Status**: ⚠️ NEEDS VERIFICATION

**Requirements**:
- Method name: `Delete{Resource}` (singular form)
- Request: `Delete{Resource}Request`, Response: `google.protobuf.Empty`
- Request MUST have `string name` field
- HTTP verb: DELETE
- URI: `/v1/{name=collection/*/resource/*}`
- No body
- method_signature: `"name"`

**Current Status**:
- DeleteMacro, DeleteObservation, DeleteSession, CloseWindow exist ✅
- Need to verify request message structure

### AIP-136: Custom Methods
**Status**: ⚠️ NEEDS VERIFICATION

**Requirements**:
- Name MUST NOT contain prepositions ("for", "with")
- Name MUST NOT use standard method verbs (Get, List, Create, Update, Delete)
- HTTP method: GET for read-only, POST for mutations
- POST methods: URI ends with `:{verb}` (e.g., `:archive`)
- Custom method on resource: MUST use `name` field as only URI variable
- Body: `"*"` for POST

**Current Violations**:
- ❌ Need to verify ALL custom methods follow :verb pattern
- ❌ FocusWindow, MoveWindow, ResizeWindow, MinimizeWindow, RestoreWindow should use :verb URIs
- ❌ ExecuteMacro, ReplayMacro, ExecuteScript should use :verb URIs
- ❌ StartObservation, StopObservation should use :verb URIs
- ❌ CommitTransaction, RollbackTransaction should use :verb URIs

**FIX PATTERN**:
```proto
// CORRECT:
rpc FocusWindow(FocusWindowRequest) returns (Window) {
  option (google.api.http) = {
    post: "/v1/{name=applications/*/windows/*}:focus"
    body: "*"
  };
}
```

### AIP-148: Standard Fields
**Status**: 🔴 VIOLATIONS EXIST

**Requirements**:
- `name`: Reserved for resource names only, MUST be IDENTIFIER behavior
- `display_name`: Use for human-readable names
- `parent`: Use in List/Create for collection parent
- NO other fields can be called `name` except resource name

**Current Violations**:
- Need to verify no misuse of `name` field
- Need to verify proper use of display_name vs name

### AIP-151: Long-Running Operations
**Status**: ⚠️ NEEDS VERIFICATION

**Requirements**:
- Return type: `google.longrunning.Operation`
- MUST include `google.longrunning.operation_info` annotation with:
  - `response_type`: what method would return if not LRO
  - `metadata_type`: progress/status information
- Both response_type and metadata_type MUST be specified
- Metadata type SHOULD NOT be google.protobuf.Empty

**Current Status**:
- No LRO methods currently defined
- Consider for expensive operations (ExecuteScript, ExecuteMacro, large file operations)

### AIP-156: Singleton Resources
**Status**: ⚠️ NEEDS VERIFICATION

**Requirements**:
- Singletons always exist with parent
- No Create or Delete methods
- Use static segment in pattern (e.g., `users/*/settings`)
- MUST specify singular and plural in resource annotation
- List method accepts parent but returns collection of one

**Current Status**:
- No singleton resources currently defined
- Consider for Settings, SystemState

### AIP-158: Pagination
**Status**: 🔴 VIOLATIONS EXIST

**Requirements**:
- List request MUST have:
  - `int32 page_size`: OPTIONAL, default documented
  - `string page_token`: OPTIONAL
- List response MUST have:
  - `repeated {Resource}`: first field, field number 1
  - `string next_page_token`: empty = end of collection
- Page tokens MUST be opaque (not user-parseable)
- Pagination CANNOT be added later (breaking change)

**Current Violations**:
- Need to verify ALL List methods have pagination fields
- ListWindows needs verification
- ListApplications needs verification
- ListElements needs verification
- ListMacros needs verification
- ListObservations needs verification

### AIP-162: Resource Revisions
**Status**: 🔴 CRITICAL VIOLATIONS

**Requirements**:
- Rollback method MUST have `string name` field (resource being rolled back)
- Rollback method MUST have `string revision_id` field
- CommitTransaction method MUST have `string name` field
- CommitTransaction method MUST have `string revision_id` field if versioned

**Current Violations**:
- ❌ CommitTransactionRequest needs `name` field (8 warnings)
- ❌ RollbackTransactionRequest needs `name` and `revision_id` fields (8 warnings)

**FIX PATTERN**:
```proto
message CommitTransactionRequest {
  // The name of the session to commit.
  // Format: sessions/{session}
  string name = 1 [
    (google.api.field_behavior) = REQUIRED,
    (google.api.resource_reference) = {
      type: "macosusesdk.googleapis.com/Session"
    }
  ];
  
  // Optional: revision ID for optimistic concurrency control
  string revision_id = 2 [(google.api.field_behavior) = OPTIONAL];
}

message RollbackTransactionRequest {
  // The name of the session to rollback.
  // Format: sessions/{session}
  string name = 1 [
    (google.api.field_behavior) = REQUIRED,
    (google.api.resource_reference) = {
      type: "macosusesdk.googleapis.com/Session"
    }
  ];
  
  // The revision to rollback to
  string revision_id = 2 [(google.api.field_behavior) = REQUIRED];
}
```

### AIP-193: Errors
**Status**: ⚠️ NEEDS VERIFICATION

**Requirements**:
- Use `google.rpc.Status` for all errors
- Use canonical error codes from `google.rpc.Code`
- Error message MUST be brief but actionable
- Status.details MUST include `ErrorInfo` with:
  - `reason`: UPPER_SNAKE_CASE identifier (e.g., `CPU_AVAILABILITY`)
  - `domain`: globally unique (e.g., `macosusesdk.googleapis.com`)
  - `metadata`: key/value pairs for context
- PERMISSION_DENIED: If user lacks permission (check before existence)
- NOT_FOUND: If resource doesn't exist (after permission check)
- INVALID_ARGUMENT: For invalid input
- ALREADY_EXISTS: For duplicate resources
- ABORTED: For concurrency conflicts (etag mismatch)

**Current Status**:
- Server implementation uses GRPCStatus correctly ✅
- Need to add proper ErrorInfo details in error responses

### AIP-203: Field Behavior
**Status**: 🔴 CRITICAL VIOLATIONS

**Requirements**:
- EVERY field in request message MUST have field_behavior annotation
- MUST use one of: REQUIRED, OPTIONAL, OUTPUT_ONLY, IDENTIFIER, IMMUTABLE, INPUT_ONLY
- `name` field (resource name) MUST use IDENTIFIER
- Fields in request messages: REQUIRED or OPTIONAL
- Fields in resources: REQUIRED, OPTIONAL, OUTPUT_ONLY, IMMUTABLE, INPUT_ONLY
- `page_size`, `page_token` MUST be OPTIONAL
- `update_mask` MUST be OPTIONAL

**Current Violations**:
- ❌ ~50+ fields missing field_behavior annotations across all protos
- ❌ Macro.proto: 9 warnings - missing annotations on ~30 fields
- ❌ Script.proto: 6 warnings - missing annotations
- ❌ Metrics.proto: 10 warnings - missing annotations
- ❌ Clipboard.proto: 7 warnings - missing annotations
- ❌ Session.proto: 8 warnings - missing annotations
- ❌ Element_methods.proto: 14 warnings - missing annotations
- ❌ Observation.proto: 1 warning - missing annotations
- ❌ Input.proto: 1 warning - field naming issue

**FIX PATTERN**:
```proto
message GetElementRequest {
  string name = 1 [
    (google.api.field_behavior) = REQUIRED,
    (google.api.resource_reference) = {
      type: "macosusesdk.googleapis.com/Element"
    }
  ];
}

message ListWindowsRequest {
  string parent = 1 [
    (google.api.field_behavior) = REQUIRED,
    (google.api.resource_reference) = {
      child_type: "macosusesdk.googleapis.com/Window"
    }
  ];
  
  int32 page_size = 2 [(google.api.field_behavior) = OPTIONAL];
  string page_token = 3 [(google.api.field_behavior) = OPTIONAL];
}

message Window {
  string name = 1 [(google.api.field_behavior) = IDENTIFIER];
  
  string title = 2 [(google.api.field_behavior) = OUTPUT_ONLY];
  
  Bounds bounds = 3 [(google.api.field_behavior) = OPTIONAL];
  
  google.protobuf.Timestamp create_time = 4 [
    (google.api.field_behavior) = OUTPUT_ONLY
  ];
}
```

### AIP-210: Unicode Handling
**Status**: ✅ NO VIOLATIONS

**Requirements**:
- Resource IDs with Unicode: Must document normalization form
- Use NFC (Normalization Form C) by default

**Current Status**:
- Resource IDs use standard formats (PIDs, UUIDs)
- No Unicode-specific handling needed

### AIP-214: Resource Expiration
**Status**: ⚠️ NEEDS CONSIDERATION

**Requirements**:
- Use `google.protobuf.Timestamp expire_time` field
- For TTL input: use `oneof expiration` with `google.protobuf.Duration ttl` as INPUT_ONLY
- Always return expire_time, leave ttl blank on retrieval

**Current Status**:
- Consider for Session, Observation resources
- Not yet implemented

### AIP-216: States
**Status**: ⚠️ NEEDS VERIFICATION

**Requirements**:
- State enum MUST have UNSPECIFIED as value 0
- State field MUST be OUTPUT_ONLY
- State MUST NOT be directly settable via Create/Update
- Use custom state transition methods (e.g., :publish, :suspend)

**Current Status**:
- ObservationState enum exists in observation.proto ✅
- Need to verify STATE_UNSPECIFIED = 0
- Need to verify state field is OUTPUT_ONLY

## Current Linter Warnings Summary

**Total**: ~125 warnings (MANDATORY: MUST BE ZERO)

### By File:
- macos_use.proto: 69 warnings (many Get method violations)
- element_methods.proto: 14 warnings (GetElement/GetElementActions patterns)
- macro.proto: 9 warnings (field_behavior annotations)
- session.proto: 8 warnings (transaction methods, field_behavior)
- metrics.proto: 10 warnings (field_behavior)
- clipboard.proto: 7 warnings (field_behavior)
- script.proto: 6 warnings (field_behavior)
- observation.proto: 1 warning (file layout)
- input.proto: 1 warning (collection naming)

### By Category:
- **Get method violations** (AIP-131): ~25 warnings
- **Field behavior missing** (AIP-203): ~50 warnings
- **Transaction method fields** (AIP-162): ~8 warnings
- **Response naming** (various AIPs): ~8 warnings
- **HTTP annotations** (AIP-136): unknown count
- **File layout/naming** (AIP-191): ~2 warnings

## Action Plan

### Phase 1: Fix AIP-131 Violations (Get Methods)
Priority: CRITICAL

Files to fix:
1. element_methods.proto: GetElement, GetElementActions
2. session.proto: GetSession, GetSessionSnapshot
3. clipboard.proto: GetClipboard, GetClipboardHistory
4. metrics.proto: GetMetrics, GetPerformanceReport
5. script.proto: GetScriptingDictionaries

Pattern: Replace `parent` + `{resource}_id` with single `string name` field.

### Phase 2: Fix AIP-203 Violations (Field Behavior)
Priority: CRITICAL

Add field_behavior annotations to ALL fields in:
1. macro.proto (~30 fields)
2. metrics.proto (~20 fields)
3. clipboard.proto (~15 fields)
4. session.proto (~15 fields)
5. script.proto (~10 fields)
6. element_methods.proto (~10 fields)
7. observation.proto (~5 fields)

### Phase 3: Fix AIP-162 Violations (Transactions)
Priority: CRITICAL

Fix transaction methods in session.proto:
1. CommitTransactionRequest: add `name` field
2. RollbackTransactionRequest: add `name` and `revision_id` fields

### Phase 4: Fix AIP-136 Violations (Custom Methods)
Priority: HIGH

Verify/fix HTTP annotations for custom methods:
1. Window operations: :focus, :move, :resize, :minimize, :restore
2. Macro operations: :execute, :replay
3. Script operations: :execute
4. Observation operations: :start, :stop
5. Session operations: :commit, :rollback

### Phase 5: Add Resource Annotations (AIP-123)
Priority: HIGH

Add google.api.resource annotations to:
1. Window
2. Application
3. Element
4. Observation
5. Session
6. Macro
7. Script

### Phase 6: Verify Standard Methods (AIPs 131-135)
Priority: MEDIUM

Verify all standard methods follow patterns:
1. Get methods (AIP-131)
2. List methods with pagination (AIP-132, AIP-158)
3. Create methods (AIP-133)
4. Update methods with update_mask (AIP-134)
5. Delete methods (AIP-135)

### Phase 7: Response Message Naming
Priority: MEDIUM

Fix response message names (8 instances identified by linter)

### Phase 8: Final Verification
Priority: CRITICAL

1. Run google-api-linter: MUST show ZERO warnings
2. Run buf generate: MUST succeed
3. Update server implementations for any proto signature changes
4. Run all tests: MUST pass
5. Verify HTTP annotations in generated code

## References

- AIP Site: https://google.aip.dev/
- AIPs Used:
  - AIP-121: Resource-oriented design
  - AIP-122: Resource names
  - AIP-123: Resource types
  - AIP-131: Get
  - AIP-132: List
  - AIP-133: Create
  - AIP-134: Update
  - AIP-135: Delete
  - AIP-136: Custom methods
  - AIP-148: Standard fields
  - AIP-151: Long-running operations
  - AIP-156: Singleton resources
  - AIP-158: Pagination
  - AIP-162: Resource revisions
  - AIP-193: Errors
  - AIP-203: Field behavior
  - AIP-210: Unicode
  - AIP-214: Resource expiration
  - AIP-216: States

## Completion Criteria

✅ **DONE** when:
1. google-api-linter shows EXACTLY ZERO warnings
2. All Get methods use `name` field pattern
3. ALL fields have field_behavior annotations
4. All transaction methods have required fields
5. All custom methods use :verb URI pattern
6. All resources have google.api.resource annotations
7. All List methods support pagination
8. buf generate succeeds
9. Server implementations updated for proto changes
10. All tests pass
