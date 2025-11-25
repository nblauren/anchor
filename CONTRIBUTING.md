# Contributing to Anchor

Thank you for your interest in contributing to Anchor! This document provides guidelines and best practices for contributing to the project.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [Development Setup](#development-setup)
- [Coding Standards](#coding-standards)
- [Testing Requirements](#testing-requirements)
- [Pull Request Process](#pull-request-process)
- [Commit Message Conventions](#commit-message-conventions)
- [Feature Development Workflow](#feature-development-workflow)
- [Bug Reports](#bug-reports)
- [Feature Requests](#feature-requests)

## Code of Conduct

### Our Pledge

Anchor is built for the LGBTQ+ community, and we are committed to providing a welcoming, inclusive, and harassment-free experience for everyone, regardless of:

- Sexual orientation, gender identity, or gender expression
- Age, race, ethnicity, or nationality
- Religion or lack thereof
- Disability or appearance
- Level of experience or education

### Our Standards

**Positive behavior includes:**
- Using welcoming and inclusive language
- Being respectful of differing viewpoints and experiences
- Gracefully accepting constructive criticism
- Focusing on what is best for the community
- Showing empathy towards other community members

**Unacceptable behavior includes:**
- Harassment, trolling, or discriminatory comments
- Sexual language or imagery
- Personal or political attacks
- Publishing others' private information without permission
- Any conduct that would be inappropriate in a professional setting

### Enforcement

Violations of the Code of Conduct should be reported to [your.email@example.com]. All complaints will be reviewed and investigated promptly and fairly.

## Getting Started

### Prerequisites

Before contributing, ensure you have:

- **Flutter SDK 3.10.0 or higher** installed
- **Xcode 14+** (for iOS development)
- **Android Studio** (for Android development)
- **Git** for version control
- **Physical devices** for BLE testing (simulators won't work)

### Fork and Clone

1. Fork the Anchor repository on GitHub
2. Clone your fork locally:
   ```bash
   git clone https://github.com/yourusername/anchor.git
   cd anchor
   ```
3. Add upstream remote:
   ```bash
   git remote add upstream https://github.com/originalowner/anchor.git
   ```

### Stay Updated

Regularly sync your fork with upstream:

```bash
git fetch upstream
git checkout main
git merge upstream/main
git push origin main
```

## Development Setup

### 1. Install Dependencies

```bash
flutter pub get
```

### 2. iOS Setup

```bash
cd ios
pod install
cd ..
```

### 3. Generate Code (if modifying database)

```bash
dart run build_runner build --delete-conflicting-outputs
```

### 4. Run on Physical Device

**⚠️ Important**: BLE doesn't work on simulators. You must use physical devices.

```bash
# List available devices
flutter devices

# Run on specific device
flutter run -d <device-id>
```

### 5. Enable Verbose Logging

For debugging BLE issues, enable verbose logging:

```dart
// In lib/services/ble/flutter_blue_plus_ble_service.dart
// Uncomment debug logs or set log level to DEBUG
```

## Coding Standards

### Dart Style Guide

Follow the [official Dart style guide](https://dart.dev/guides/language/effective-dart/style):

- Use `camelCase` for variables and functions
- Use `PascalCase` for classes and types
- Use `snake_case` for file names
- Use `SCREAMING_SNAKE_CASE` for constants

### Flutter Best Practices

1. **Widget Organization**
   - Extract complex widgets into separate files
   - Use `const` constructors wherever possible
   - Keep widget build methods small (<50 lines)

2. **State Management**
   - Use Bloc pattern for business logic
   - Keep UI widgets stateless when possible
   - Don't mix business logic in UI code

3. **File Organization**
   - Follow feature-based architecture
   - Keep related files together
   - Use barrel files (`export` files) for clean imports

### Code Quality

**Run before committing**:

```bash
# Format code
flutter format .

# Analyze code
flutter analyze

# Run tests
flutter test
```

**Linting**: The project uses standard Flutter lints. Resolve all warnings before submitting PR.

### Documentation

**Code Comments**:
- Document public APIs with `///` doc comments
- Explain **why**, not **what** (code should be self-documenting)
- Update comments when changing code

**Example**:
```dart
/// Discovers nearby peers using BLE scanning.
///
/// Scans for devices advertising Anchor's service UUID and emits
/// [DiscoveredPeer] events when profiles are successfully read.
///
/// Throws [BleError] if Bluetooth is unavailable or permissions denied.
Future<void> startScanning() async {
  // Implementation
}
```

## Testing Requirements

### Unit Tests

**Required for**:
- All repositories
- All blocs
- Complex business logic

**Example**:
```dart
// test/data/repositories/profile_repository_test.dart
void main() {
  group('ProfileRepository', () {
    late ProfileRepository repository;
    late Database database;

    setUp(() {
      database = _createInMemoryDatabase();
      repository = ProfileRepository(database);
    });

    test('createProfile creates and returns profile', () async {
      final profile = await repository.createProfile(
        name: 'John',
        age: 28,
        bio: 'Hey!',
      );

      expect(profile.name, 'John');
      expect(profile.age, 28);
    });
  });
}
```

### Integration Tests

**Required for**:
- New features that span multiple components
- BLE communication flows (use MockBleService)

**Example**:
```dart
// test/integration/discovery_flow_test.dart
void main() {
  testWidgets('Discovery flow shows discovered peers', (tester) async {
    final mockBle = MockBleService();

    await tester.pumpWidget(MyApp(bleService: mockBle));

    // Simulate peer discovered
    mockBle.emitPeerDiscovered(mockPeer);
    await tester.pump();

    // Verify peer appears in UI
    expect(find.text('John'), findsOneWidget);
  });
}
```

### Device Testing

**Before submitting PR**, manually test on physical devices:

1. **Basic Discovery**: 2 devices discover each other
2. **Messaging**: Send/receive text messages
3. **Permissions**: Deny/grant permissions flow works
4. **Edge Cases**: Bluetooth off, out of range, etc.

**Document test results** in PR description:
```
Tested on:
- iPhone 13 (iOS 17.2) ✅
- Samsung Galaxy S21 (Android 13) ✅

Test scenarios:
- Discovery: ✅ Works
- Messaging: ✅ Works
- Permissions: ✅ Works
```

## Pull Request Process

### 1. Create Feature Branch

```bash
git checkout -b feature/your-feature-name
```

**Branch naming**:
- `feature/description` - New features
- `fix/description` - Bug fixes
- `refactor/description` - Code refactoring
- `docs/description` - Documentation updates
- `test/description` - Test additions

### 2. Make Changes

- Write clean, documented code
- Follow coding standards
- Add tests for new functionality
- Update documentation if needed

### 3. Commit Changes

```bash
git add .
git commit -m "feat: Add photo transfer with chunking"
```

See [Commit Message Conventions](#commit-message-conventions) below.

### 4. Push to Fork

```bash
git push origin feature/your-feature-name
```

### 5. Create Pull Request

1. Go to your fork on GitHub
2. Click "Compare & pull request"
3. Fill out PR template (see below)
4. Request review from maintainers

### PR Template

```markdown
## Description
Brief description of what this PR does.

## Type of Change
- [ ] Bug fix (non-breaking change which fixes an issue)
- [ ] New feature (non-breaking change which adds functionality)
- [ ] Breaking change (fix or feature that would cause existing functionality to not work as expected)
- [ ] Documentation update

## Testing
Describe how you tested this change:

- [ ] Unit tests added/updated
- [ ] Integration tests added/updated
- [ ] Manually tested on physical devices

**Devices tested**:
- iOS: [device and version]
- Android: [device and version]

## Screenshots (if applicable)
Add screenshots or screen recordings of UI changes.

## Checklist
- [ ] Code follows project style guidelines
- [ ] Self-review completed
- [ ] Code commented where necessary
- [ ] Documentation updated
- [ ] No new warnings from `flutter analyze`
- [ ] Tests added/updated and passing
- [ ] Manually tested on physical devices
```

### 6. Review Process

- Maintainers will review your PR
- Address feedback by pushing new commits
- Once approved, maintainers will merge

### 7. After Merge

Delete your feature branch:

```bash
git checkout main
git pull upstream main
git branch -d feature/your-feature-name
git push origin --delete feature/your-feature-name
```

## Commit Message Conventions

We follow [Conventional Commits](https://www.conventionalcommits.org/) for clear commit history.

### Format

```
<type>(<scope>): <subject>

<body>

<footer>
```

### Type

- `feat`: New feature
- `fix`: Bug fix
- `refactor`: Code change that neither fixes a bug nor adds a feature
- `docs`: Documentation only changes
- `style`: Changes that don't affect code meaning (formatting, etc.)
- `test`: Adding or updating tests
- `chore`: Changes to build process, dependencies, etc.
- `perf`: Performance improvements

### Scope (optional)

Component affected: `ble`, `profile`, `chat`, `discovery`, `database`, etc.

### Subject

- Use imperative mood ("Add feature" not "Added feature")
- Don't capitalize first letter
- No period at the end
- Limit to 50 characters

### Body (optional)

- Wrap at 72 characters
- Explain **what** and **why**, not **how**
- Separate from subject with blank line

### Footer (optional)

- Reference issues: `Fixes #123` or `Closes #456`
- Breaking changes: `BREAKING CHANGE: description`

### Examples

**Simple commit**:
```
feat: add photo transfer with chunking
```

**Commit with scope**:
```
fix(ble): resolve connection timeout on iOS
```

**Commit with body**:
```
feat(chat): add store-and-forward message queue

Messages now queue when peer is offline and automatically
deliver when peer is rediscovered. Includes retry logic
with exponential backoff and 24-hour expiration.

Fixes #42
```

**Breaking change**:
```
refactor(database)!: change peer table schema

BREAKING CHANGE: The discovered_peers table now includes
a last_seen_at column. Existing databases will need migration.
```

## Feature Development Workflow

### Planning

1. **Check existing issues** - Is this already planned or in progress?
2. **Create issue** - Describe the feature, use cases, and approach
3. **Get feedback** - Wait for maintainer approval before starting work
4. **Break it down** - Split large features into smaller, reviewable PRs

### Implementation

1. **Start small** - Begin with core functionality, add enhancements later
2. **Test as you go** - Write tests alongside implementation
3. **Document** - Update docs and add code comments
4. **Self-review** - Review your own code before requesting review

### Review Iterations

1. **Address feedback promptly** - Respond within a few days
2. **Push fixup commits** - Don't force-push during review
3. **Ask questions** - If feedback is unclear, ask for clarification
4. **Be patient** - Maintainers volunteer their time

## Bug Reports

### Before Reporting

1. **Search existing issues** - Has this been reported?
2. **Try latest version** - Is this fixed in main branch?
3. **Reproduce** - Can you consistently reproduce it?

### Bug Report Template

```markdown
**Describe the bug**
A clear description of what the bug is.

**To Reproduce**
Steps to reproduce:
1. Go to '...'
2. Tap on '...'
3. See error

**Expected behavior**
What you expected to happen.

**Actual behavior**
What actually happened.

**Screenshots**
If applicable, add screenshots.

**Device Information**
- Device: [e.g., iPhone 13, Samsung Galaxy S21]
- OS: [e.g., iOS 17.2, Android 13]
- Anchor Version: [e.g., 1.0.0]
- Flutter Version: [e.g., 3.10.0]

**Logs**
If applicable, add logs from Debug Menu > View Logs.

**Additional context**
Any other relevant information.
```

## Feature Requests

### Before Requesting

1. **Search existing issues** - Has this been requested?
2. **Check roadmap** - Is this already planned?
3. **Consider scope** - Does this fit Anchor's core mission?

### Feature Request Template

```markdown
**Problem**
What problem does this solve?

**Proposed Solution**
Describe your proposed solution.

**Alternatives Considered**
What alternatives did you consider?

**Use Case**
Describe a specific scenario where this would be useful.

**Implementation Notes**
(Optional) Technical notes on how this could be implemented.

**Additional Context**
Any other relevant information.
```

## Specific Contribution Areas

### BLE Development

**If you're working on BLE features**:
- Test on **both iOS and Android** (BLE behaves differently)
- Use **physical devices** (BLE doesn't work on simulators)
- Test with **multiple devices** (2-5 devices in range)
- Monitor **battery usage** (use Battery Profiler)
- Consider **cruise ship environment** (metal interference, density, movement)

**Key files**:
- `lib/services/ble/flutter_blue_plus_ble_service.dart`
- `lib/services/ble/ble_models.dart`
- `lib/services/ble/photo_chunker.dart`

### Database Development

**If you're working on database features**:
- Use **Drift migrations** for schema changes
- Write **unit tests** with in-memory database
- Consider **performance** for large datasets (e.g., 1000+ messages)
- Add **indexes** for frequently queried columns

**Key files**:
- `lib/data/database.dart`
- `lib/data/repositories/*.dart`

### UI Development

**If you're working on UI features**:
- Follow **Material Design 3** guidelines
- Support **dark theme** (our primary theme)
- Test on **different screen sizes** (phones, tablets)
- Add **loading states, error states, empty states**
- Ensure **accessibility** (screen readers, font scaling)

**Key files**:
- `lib/features/*/screens/*.dart`
- `lib/core/widgets/*.dart`
- `lib/core/theme/app_theme.dart`

## Getting Help

**Stuck on something?**

1. **Check documentation** - README, ARCHITECTURE, this file
2. **Search issues** - Someone may have asked already
3. **Ask in Discussions** - GitHub Discussions for questions
4. **Ask maintainers** - Comment on related issue or PR

**Common issues**:

- **BLE not working**: Are you using a physical device? Is Bluetooth on?
- **Build errors**: Try `flutter clean && flutter pub get`
- **Pod install fails**: Try `cd ios && pod repo update && pod install`
- **Drift errors**: Run `dart run build_runner build --delete-conflicting-outputs`

## Recognition

Contributors will be recognized in:
- GitHub contributors page
- Release notes (for significant contributions)
- Special thanks in README (for major features)

## Questions?

- **Email**: your.email@example.com
- **GitHub Discussions**: [Link]
- **GitHub Issues**: [Link]

---

**Thank you for contributing to Anchor!** Your work helps create a better experience for the LGBTQ+ community on cruises and festivals worldwide. 🏳️‍🌈⚓
