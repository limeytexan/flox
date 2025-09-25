# Flox Activate Refactor Project Plan

## Executive Summary

This document outlines the project plan for refactoring the `flox activate` command architecture. The current design uses a complex system of bash scripts coordinated by the `flox-activations` binary. The new design introduces a simplified Registry Module and Executive system with better separation of concerns and cleaner lifecycle management.

## Current Architecture Analysis

### Current Components
- **flox CLI** (`cli/flox/src/commands/activate.rs`): Main entry point, handles argument parsing and initial setup
- **flox-activations** (`cli/flox-activations/src/`): Rust binary managing activation state
- **Bash Scripts** (`assets/environment-interpreter/`): Complex activation flow logic
  - `activate`: Main activation script
  - `start.bash`: Environment initialization and hook execution
  - `attach.bash`: Environment restoration from state files
  - `attach-*.bash`: Various attachment modes (interactive, command, in-place)
- **Watchdog Process**: Background cleanup and monitoring

### Current Flow
1. CLI initializes state and calls activation script
2. Activation script calls `flox-activations start-or-attach`
3. Based on result, either starts new activation or attaches to existing
4. Complex bash script orchestration manages environment setup
5. Watchdog process monitors and cleans up

## New Architecture Vision

### New Components
- **flox CLI**: Simplified entry point with Registry Module
- **Registry Module**: Centralized activation lifecycle management
- **activation binary**: Replaces parts of flox-activations with simpler interface
- **Executive**: Enhanced watchdog with better lifecycle management
- **Simplified Bash**: Consolidated environment handling with snapshotEnv/replayEnv

### New Flow
1. CLI with Registry Module handles start/attach decisions
2. Executive manages subprocess lifecycle with enhanced monitoring
3. Simplified activation process with environment snapshots
4. Direct environment replay without complex bash orchestration

## Implementation Phases

### Phase 1: Foundation & Registry Module
**Objective**: Create new activation binary and implement Registry Module

#### Tasks:
1. **Create new `activation` binary** (`cli/flox-activation/`)
   - Set up new Rust crate structure
   - Implement basic CLI with clap
   - Add core activation state management
   - Add environment snapshot functionality (`snapshotEnv()`)
   - Add environment replay functionality (`replayEnv()`)

2. **Implement Registry Module** in flox CLI
   - Add registry logic to `cli/flox/src/commands/activate.rs`
   - Implement exists/active/ready checks
   - Add do_start() and do_attach() functions
   - Handle fork() and process management
   - Integrate with existing activation state directory structure

3. **Update CLI Integration**
   - Modify activate command to use Registry Module
   - Update argument passing to new system
   - Maintain backward compatibility during transition

#### Deliverables:
- [ ] New `cli/flox-activation/` crate with basic functionality
- [ ] Registry Module integrated into activate.rs
- [ ] Environment snapshot/replay functionality
- [ ] Unit tests for new components

#### Estimated Duration: 2-3 weeks

### Phase 2: Executive & Process Management
**Objective**: Replace watchdog with enhanced Executive system

#### Tasks:
1. **Implement Executive** (enhanced watchdog)
   - Add subreaper functionality (`setsid()`, register as subreaper)
   - Enhanced PID monitoring (await death of ppid() and registry_PIDs)
   - Improved cleanup logic (remove temp files, state management)
   - Better error handling and metrics submission
   - Process supervision for process-compose

2. **Update Process Management**
   - Implement proper fork() handling in Registry Module
   - Add parent/child process coordination
   - Update activation ready signaling mechanism
   - Handle process-compose supervisor integration

3. **Environment Initialization**
   - Update environment snapshot timing (env0, env1, env2)
   - Simplify profile sourcing logic
   - Consolidate hook.on-activate execution
   - Streamline environment variable management

#### Deliverables:
- [ ] Enhanced Executive with subreaper functionality
- [ ] Improved process lifecycle management
- [ ] Simplified environment initialization flow
- [ ] Integration tests for process management

#### Estimated Duration: 2-3 weeks

### Phase 3: Bash Script Consolidation
**Objective**: Simplify and consolidate bash activation scripts

#### Tasks:
1. **Consolidate Activation Scripts**
   - Replace multiple attach-*.bash scripts with single consolidated logic
   - Implement replayEnv() function for environment restoration
   - Simplify userShell integration
   - Update in-place activation handling

2. **Update Profile Sourcing**
   - Streamline etc-profiles sourcing
   - Consolidate profile.common and profile.$userShell handling
   - Update environment variable replay mechanism

3. **Command Execution Simplification**
   - Simplify command vs interactive mode handling
   - Update shell detection and execution logic
   - Improve error handling and messaging

#### Deliverables:
- [ ] Consolidated bash activation scripts
- [ ] Simplified replayEnv() implementation
- [ ] Updated userShell integration
- [ ] Shell script tests and validation

#### Estimated Duration: 2 weeks

### Phase 4: Testing & Integration
**Objective**: Comprehensive testing of new architecture

#### Tasks:
1. **Unit Testing**
   - Test Registry Module functionality
   - Test activation binary commands
   - Test Executive process management
   - Test environment snapshot/replay
   - Validate error handling and edge cases

2. **Integration Testing**
   - End-to-end activation flow testing
   - Multi-environment activation testing
   - Service startup integration testing
   - Shell compatibility testing (bash, zsh, fish, tcsh)
   - In-place vs interactive vs command mode testing

3. **Performance & Reliability Testing**
   - Activation performance benchmarking
   - Process cleanup verification
   - Memory leak testing
   - Concurrent activation testing
   - Error recovery testing

4. **Test Infrastructure Updates**
   - Update existing test suites for new architecture
   - Add integration tests for Registry Module
   - Update bash script tests
   - Validate backward compatibility

#### Deliverables:
- [ ] Comprehensive unit test suite
- [ ] Integration test coverage
- [ ] Performance benchmarks
- [ ] Updated test infrastructure
- [ ] Compatibility validation

#### Estimated Duration: 2-3 weeks

### Phase 5: Migration & Cleanup
**Objective**: Remove old components and finalize transition

#### Tasks:
1. **Remove Legacy Components**
   - Phase out old flox-activations commands
   - Remove obsolete bash scripts
   - Clean up unused code paths
   - Update documentation

2. **Final Integration**
   - Complete CLI integration with new system
   - Remove compatibility shims
   - Validate all use cases work correctly
   - Update error messages and help text

3. **Documentation & Communication**
   - Update architecture documentation
   - Update user-facing documentation if needed
   - Create migration notes for developers
   - Update troubleshooting guides

#### Deliverables:
- [ ] Legacy code removal completed
- [ ] Clean, integrated new architecture
- [ ] Updated documentation
- [ ] Developer migration guide

#### Estimated Duration: 1-2 weeks

## Testing Strategy

### Unit Testing
- **Registry Module**: Test activation lifecycle state management
- **activation binary**: Test command interface and environment operations
- **Executive**: Test process management and cleanup logic
- **Environment handling**: Test snapshot and replay functionality

### Integration Testing
- **Full activation flows**: Test complete activate scenarios
- **Multi-shell support**: Validate bash, zsh, fish, tcsh compatibility
- **Service integration**: Test service startup and management
- **Error scenarios**: Test failure modes and recovery
- **Concurrent usage**: Test multiple simultaneous activations

### Performance Testing
- **Activation speed**: Benchmark activation time vs current implementation
- **Memory usage**: Monitor memory consumption during activation
- **Process overhead**: Validate Executive process management efficiency

### Regression Testing
- **Existing functionality**: Ensure all current features continue working
- **Edge cases**: Test corner cases and error conditions
- **Compatibility**: Validate environment compatibility across systems

## Risk Assessment & Mitigation

### High Risks
1. **Breaking existing functionality**
   - *Mitigation*: Comprehensive testing and gradual rollout
   - *Plan*: Feature flags for gradual activation of new system

2. **Performance regression**
   - *Mitigation*: Continuous benchmarking during development
   - *Plan*: Performance targets established and monitored

3. **Complex process management bugs**
   - *Mitigation*: Thorough testing of Executive process handling
   - *Plan*: Extended testing period with focus on edge cases

### Medium Risks
1. **Shell compatibility issues**
   - *Mitigation*: Testing across all supported shells
   - *Plan*: Shell-specific test suites and validation

2. **Service startup integration complexity**
   - *Mitigation*: Careful integration testing with process-compose
   - *Plan*: Service startup testing in multiple scenarios

### Low Risks
1. **Documentation gaps**
   - *Mitigation*: Documentation updates included in each phase
   - *Plan*: Regular documentation reviews

## Success Criteria

### Functional Requirements
- [ ] All current activation modes work correctly (interactive, command, in-place)
- [ ] Multi-environment activation support maintained
- [ ] Service startup integration preserved
- [ ] All supported shells continue working (bash, zsh, fish, tcsh)
- [ ] Error handling and user messages remain clear and helpful

### Non-Functional Requirements
- [ ] Activation performance equal to or better than current implementation
- [ ] Memory usage does not increase significantly
- [ ] Code complexity reduced (measured by cyclomatic complexity)
- [ ] Test coverage maintained or improved
- [ ] Architecture is more maintainable and easier to understand

### Quality Gates
- [ ] All existing tests pass with new implementation
- [ ] New test coverage meets project standards
- [ ] Performance benchmarks meet established targets
- [ ] Code review approval for all changes
- [ ] Documentation updated and reviewed

## Project Timeline

**Total Estimated Duration: 10-13 weeks**

- **Phase 1**: Weeks 1-3 (Foundation & Registry Module)
- **Phase 2**: Weeks 4-6 (Executive & Process Management)
- **Phase 3**: Weeks 7-8 (Bash Script Consolidation)
- **Phase 4**: Weeks 9-11 (Testing & Integration)
- **Phase 5**: Weeks 12-13 (Migration & Cleanup)

## Dependencies

### Internal Dependencies
- flox-core activation management APIs
- Environment rendering and linking system
- Service startup and process-compose integration
- Metrics and telemetry systems

### External Dependencies
- No significant external dependencies identified
- Standard Unix process management APIs
- Shell compatibility requirements

## Conclusion

This refactoring represents a significant architectural improvement that will simplify the activation system while maintaining all existing functionality. The phased approach minimizes risk while ensuring thorough testing and validation at each step.

The new Registry Module and Executive design provides better separation of concerns, cleaner error handling, and improved maintainability for future development.

---

**Document Version**: 1.0
**Last Updated**: 2025-09-25
**Status**: Planning Phase