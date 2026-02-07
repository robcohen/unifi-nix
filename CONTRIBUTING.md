# Contributing to unifi-nix

Thank you for your interest in contributing to unifi-nix! This document provides guidelines and instructions for contributing.

## Code of Conduct

Please be respectful and constructive in all interactions. We're all here to make UniFi configuration better with Nix.

## Getting Started

### Prerequisites

- Nix with flakes enabled
- A UniFi Dream Machine for testing (optional but recommended)

### Development Setup

```bash
# Clone the repository
git clone https://github.com/robcohen/unifi-nix
cd unifi-nix

# Enter the development shell
nix develop

# Run checks to verify everything works
nix flake check
```

## Making Changes

### 1. Fork and Clone

Fork the repository on GitHub, then clone your fork:

```bash
git clone https://github.com/YOUR_USERNAME/unifi-nix
cd unifi-nix
git remote add upstream https://github.com/robcohen/unifi-nix
```

### 2. Create a Branch

```bash
git checkout -b feature/your-feature-name
```

### 3. Make Your Changes

- Follow the existing code style
- Add tests for new functionality
- Update documentation as needed

### 4. Format and Lint

Before committing, ensure your code is properly formatted:

```bash
# Format all code
nix fmt

# Check for issues
nix develop .#ci --command statix check .
nix develop .#ci --command deadnix .
```

### 5. Run Tests

```bash
nix flake check
```

### 6. Commit Your Changes

Write clear, descriptive commit messages:

```bash
git commit -m "feat: add support for traffic routes"
```

Follow [Conventional Commits](https://www.conventionalcommits.org/):

- `feat:` - New features
- `fix:` - Bug fixes
- `docs:` - Documentation changes
- `refactor:` - Code refactoring
- `test:` - Adding or updating tests
- `chore:` - Maintenance tasks

### 7. Push and Create a Pull Request

```bash
git push origin feature/your-feature-name
```

Then create a Pull Request on GitHub.

## Code Style

### Nix

- Use `nixfmt-rfc-style` for formatting (handled by `nix fmt`)
- Follow [RFC 140](https://github.com/NixOS/rfcs/pull/140) conventions
- Use descriptive names for options
- Add documentation for all public options

Example:

```nix
myOption = mkOption {
  type = types.bool;
  default = false;
  description = "Enable the feature. When enabled, ...";
  example = true;
};
```

### Shell Scripts

- Use `shfmt` for formatting
- Use `set -euo pipefail` at the start
- Quote all variables
- Add comments for complex logic

### Documentation

- Use clear, concise language
- Include examples where helpful
- Keep the README up to date

## Testing

### Unit Tests

The Nix module includes several checks:

- `example-eval` - Verifies example configuration evaluates
- `module-structure` - Tests module can be instantiated
- `formatting` - Checks code formatting
- `statix` / `deadnix` - Static analysis

### Manual Testing

If you have a UDM available:

```bash
# Build and evaluate your config
nix run .#eval -- examples/home.nix > test-config.json

# Preview changes (safe - read only)
nix run .#diff -- test-config.json YOUR_UDM_IP

# Validate
nix run .#validate -- test-config.json
```

**Never test directly on production!** Use `DRY_RUN=true` for deploy tests.

## Areas for Contribution

### High Priority

- \[ \] Traffic routes support
- \[ \] Port profile management
- \[ \] Switch port configuration
- \[ \] RADIUS profile support

### Documentation

- Improve examples
- Add troubleshooting guide
- Document edge cases

### Testing

- Add more validation test cases
- Improve error messages
- Add integration tests

## Schema Updates

UniFi schemas are automatically extracted via CI. If you need to update schemas manually:

```bash
# Extract from a live device
./scripts/extract-schema.sh YOUR_UDM_IP

# The schema will be saved to schemas/<version>/
```

## Questions?

- Open an issue for bugs or feature requests
- Start a discussion for questions or ideas

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
