---
name: go-enterprise-quality
description: Enterprise-level Go code quality guard. Enforces multi-dimensional testing, cross-validation, and production-readiness checks on every code write. Triggers automatically when writing or editing Go files.
allowed-tools: "Read, Write, Edit, Bash, Glob, Grep"
---

# Go Enterprise Quality Guard

Every time you write or modify Go code, you MUST follow this enterprise-level quality checklist. This is non-negotiable for production readiness.

## Phase 1: Pre-Write Analysis

Before writing code, verify:
1. **Read existing code** - understand the module's patterns, error handling style, naming conventions
2. **Check interfaces** - ensure new code satisfies existing interfaces and contracts
3. **Identify dependencies** - understand what other modules depend on this code
4. **Review related tests** - read existing test files to understand testing patterns

## Phase 2: Code Writing Standards

When writing code, enforce:

### Correctness
- All error paths are handled explicitly, never silently ignored
- nil checks before dereferencing pointers
- Mutex/lock protection for shared state; verify lock/unlock pairing
- Context propagation: always pass ctx, respect cancellation and timeout
- Channel operations: verify no goroutine leak, no blocking on unbuffered channel without consumer
- Boundary checks on slice/map access

### Stability
- Graceful degradation: fallback behavior when downstream fails
- Panic recovery in goroutines (especially HTTP handlers, workers)
- Resource cleanup: defer Close() immediately after acquiring resource
- Connection pooling: reuse DB/HTTP/Redis connections, never create per-request
- Timeout on all external calls (HTTP, DB, Redis, gRPC); no indefinite blocking

### Performance
- Avoid allocation in hot paths (preallocate slices, use sync.Pool where appropriate)
- No N+1 queries - batch DB reads, use JOIN or IN clause
- String concatenation in loops must use strings.Builder
- Large struct pass by pointer, small value types pass by value
- Avoid reflect in hot paths

### Security
- SQL parameterized queries only, never string concatenation
- User input sanitization at handler boundary
- JWT validation on every protected endpoint
- Sensitive data (passwords, tokens) never logged or returned in API response
- Rate limiting on public endpoints

## Phase 3: Post-Write Verification (MANDATORY)

After writing code, you MUST perform these checks:

### 3.1 Compilation Check
```bash
go build ./...
```
If compilation fails, fix immediately before proceeding.

### 3.2 Static Analysis
```bash
go vet ./...
```
All warnings must be resolved.

### 3.3 Unit Test Verification
Run tests for the affected package:
```bash
go test -v -race -count=1 ./path/to/package/...
```
- `-race`: detect data races
- `-count=1`: disable test caching to ensure fresh run
- All tests must pass. If any fail, investigate and fix.

### 3.4 Cross-Validation Checks

Perform multi-dimensional validation:

**A. Interface Compliance**
- If a struct implements an interface, verify all methods are correctly implemented
- Check that the struct can be assigned to the interface type

**B. Caller Impact Analysis**
- Grep for all callers of modified functions
- Verify signature changes don't break callers
- Check that new error returns are handled by all callers

```bash
grep -rn "FunctionName" --include="*.go" .
```

**C. Data Flow Validation**
- Trace data from HTTP handler -> service -> repository -> DB
- Verify request binding (dto) -> domain model -> response mapping is consistent
- Check that field names, types, and JSON tags align across layers

**D. Concurrent Safety Check**
- If code touches shared state, verify mutex protection
- If code launches goroutines, verify they complete or have cancellation
- Check for potential deadlocks (lock ordering)

**E. Configuration & Environment**
- Verify new config values have defaults
- Check that environment-specific behavior is correct
- Ensure no hardcoded URLs, ports, or credentials

### 3.5 Integration Points Validation
- If modifying a handler: verify route registration, middleware chain, request/response format
- If modifying a repository: verify SQL correctness, transaction boundaries, connection release
- If modifying a service: verify business logic correctness, error propagation, event ordering
- If modifying a worker: verify retry logic, idempotency, failure recovery

## Phase 4: Test Writing Requirements

When the change is significant enough, write or update tests:

### Required Test Types
1. **Unit Tests** - test individual functions in isolation
   - Table-driven tests with edge cases
   - Test both success and error paths
   - Mock external dependencies (DB, Redis, HTTP clients)

2. **Boundary Tests** - test limits and edge cases
   - Empty input, nil input, max-length input
   - Concurrent access (use goroutines in test)
   - Timeout and cancellation behavior

3. **Error Path Tests** - verify error handling
   - DB connection failure
   - Invalid input data
   - Downstream service unavailable
   - Partial failure in batch operations

### Test Quality Checklist
- [ ] Each test has a clear name describing the scenario
- [ ] Table-driven tests for functions with multiple input combinations
- [ ] No test depends on another test's state
- [ ] Tests clean up their resources (t.Cleanup)
- [ ] Race condition tested with `-race` flag
- [ ] Error messages are descriptive and include context

## Phase 5: Final Verification

Before considering the task complete:

1. **Full build**: `go build ./...`
2. **Full vet**: `go vet ./...`
3. **Affected tests**: `go test -race -count=1 ./affected/package/...`
4. **Review diff**: read your own changes and verify they match the intent
5. **No debug artifacts**: remove any temporary log statements, TODO comments, or debug code

## Severity Levels

| Issue | Severity | Action |
|-------|----------|--------|
| Compilation error | BLOCKER | Fix immediately |
| Data race | BLOCKER | Fix immediately |
| Unhandled error | CRITICAL | Fix before completion |
| Missing nil check on pointer | CRITICAL | Fix before completion |
| No test for new logic | HIGH | Write test |
| Performance concern (N+1, etc) | HIGH | Optimize |
| Missing context propagation | MEDIUM | Fix |
| Style/naming inconsistency | LOW | Fix if touched |

## Remember

- Never skip Phase 3. "It compiles" is not enough.
- Cross-validation catches bugs that unit tests miss.
- Every modified function's callers must be checked.
- Production code must handle the unhappy path.
- When in doubt, add a test.
