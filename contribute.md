# Contributor's Guide 🌟

Welcome to DeepseekR! We're excited you're here. This guide follows standard open-source conventions while addressing our specific project needs.

## Table of Contents
1. [First-Time Setup](#-first-time-setup)
2. [Development Workflow](#-development-workflow)
3. [Contribution Areas](#-contribution-areas)
4. [Communication Practices](#-communication-practices)
5. [Code Standards](#-code-standards)
6. [Testing Philosophy](#-testing-philosophy)
7. [Pull Request Process](#-pull-request-process)
8. [Recognition](#-recognition)

## 🛠️ First-Time Setup

### Prerequisites
- Xcode 15+
- macOS 15+
- Swift Package Manager

```bash
# 1. Fork & clone
git clone https://github.com/InfinitIQ-Tech/DeepseekR.git
cd DeepseekR

# 2. Install development dependencies
swift package resolve

# 3. Open in Xcode
xed .
```

## 🔄 Development Workflow

### Branch Strategy
| Branch Type      | Naming Convention          | Purpose                          |
|------------------|----------------------------|----------------------------------|
| Primary          | `main`                     | Stable releases                  |
| Feature          | `feat/[short-description]` | New functionality                |
| Bug Fix          | `fix/[issue-number]`       | Error corrections                |
| Research         | `research/[hypothesis]`    | Experimental architectures       |

### Commit Messages
```bash
git commit -m "feat: add expert routing logic [DS-123]" 
git commit -m "docs: update MoE architecture overview"
```
- Prefix with: `feat:`, `fix:`, `docs:`, `test:`, `refactor:`, `chore:`
- Reference GitHub issues: `[DS-123]`

## 🎯 Contribution Areas

### MoE Architecture (🧩) - TODO
- Implement routing algorithms
- Develop expert qualification metrics
- Create response synthesis strategies

### Core Infrastructure (🚢)
```bash
# Performance Testing Command
swift build -c release && ./.build/release/DeepseekR benchmark
```
- Optimize Swift concurrency
- Enhance macOS accessibility
- Improve API security

## 📢 Communication Practices

1. **Issues**  
   - Use GitHub issues for:  
     - Feature requests (template provided)  
     - Bug reports (template provided)  
     - Architectural discussions  

2. **RFC Process**  
   - Major changes require a Request for Comments:  
     ```markdown
     ## [RFC] Proposed Expert Load Balancer
     **Problem Statement**:  
     Current expert selection...  
     **Proposed Solution**:  
     Implement round-robin...  
     **Alternatives Considered**:  
     1. Random selection  
     2. Performance-based routing  
     ```

## 💻 Code Standards

```swift
// Good Example
final class ExpertRouter: Sendable {
    private let experts: [any DeepseekExpert]
    
    init(experts: [any DeepseekExpert]) {
        self.experts = experts
    }
}

// Bad Example (non-Sendable state)
class ExpertRouter {
    var experts: [Any] = []
}
```
- **Must**: Thread safety via `Sendable`
- **Must**: Document public APIs with DocC
- **Avoid**: Force unwrapping (!) except tests

## 🧪 Testing Philosophy

```swift
func testExpertRouting() async throws {
    let mockExperts = [MockExpert(), MockExpert()]
    let router = ExpertRouter(experts: mockExperts)
    
    let response = try await router.handle(query: "test")
    XCTAssertContains(response, "expected_pattern")
}
```
- Prefer async/await over completion handlers
- Mock network dependencies
- 70% test coverage goal for core components

## 🔀 Pull Request Process

1. Rebase onto latest `main`
2. Request review from 2 maintainers
3. Address feedback via new commits (no force-push)

## 🏆 Recognition

- First-time contributors get shoutouts in releases
- Consistent contributors earn commit bits
- Architectural contributors join RFC review panel

```markdown
**Hall of Fame**  
[![Contributors](https://contrib.rocks/image?repo=InfinitIQ-Tech/DeepseekR)](https://github.com/InfinitIQ-Tech/DeepseekR/graphs/contributors)
```

*Many experts, one system - Your contributions shape tomorrow's AI collaboration tools!*