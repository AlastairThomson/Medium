#!/bin/bash

# launch-dev-team.sh
# Sets up a multi-agent development team with git worktrees and tmux sessions
# Each agent gets their specified persona markdown file copied to CLAUDE.md
# Supports multiple AI CLI tools: claude, gemini, codex
# Creates sandboxed environments with role-appropriate permissions

set -e

PROJECT_DIR=""
ARCHITECT_AGENT=""
ARCHITECT_MODEL=""
ARCHITECT_MARKDOWN=""
DEVELOPER_COUNT=0
FORCE_CLEANUP=false
CONTINUE_SESSION=false
USE_CCR=false
declare -a TEAM_MEMBERS=()
declare -a GUIDANCE_FILES=()

# Parse arguments
# Format: --Role=<agent>[:<model>]@<markdown_path>
parse_role_arg() {
    local arg="$1"
    local value="${arg#*=}"
    if [[ "$value" != *@* ]]; then
        echo "Error: Invalid format '$arg'. Expected --Role=<agent>[:<model>]@<markdown_path>" >&2
        exit 1
    fi
    local agent_part="${value%@*}"
    PARSED_MARKDOWN="${value#*@}"

    # Check if model is specified (agent:model format)
    if [[ "$agent_part" == *:* ]]; then
        PARSED_AGENT="${agent_part%:*}"
        PARSED_MODEL="${agent_part#*:}"
    else
        PARSED_AGENT="$agent_part"
        PARSED_MODEL=""
    fi
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --Architect=*)
            parse_role_arg "$1"
            ARCHITECT_AGENT="$PARSED_AGENT"
            ARCHITECT_MODEL="$PARSED_MODEL"
            ARCHITECT_MARKDOWN="$PARSED_MARKDOWN"
            shift
            ;;
        --Developer=*)
            parse_role_arg "$1"
            DEVELOPER_COUNT=$((DEVELOPER_COUNT + 1))
            TEAM_MEMBERS+=("Developer${DEVELOPER_COUNT}:developer:${PARSED_MARKDOWN}:${PARSED_AGENT}:${PARSED_MODEL}")
            shift
            ;;
        --UX=*)
            parse_role_arg "$1"
            TEAM_MEMBERS+=("UX:ux:${PARSED_MARKDOWN}:${PARSED_AGENT}:${PARSED_MODEL}")
            shift
            ;;
        --Security=*)
            parse_role_arg "$1"
            TEAM_MEMBERS+=("SECURITY:security:${PARSED_MARKDOWN}:${PARSED_AGENT}:${PARSED_MODEL}")
            shift
            ;;
        --Cloud=*)
            parse_role_arg "$1"
            TEAM_MEMBERS+=("CLOUD:cloud:${PARSED_MARKDOWN}:${PARSED_AGENT}:${PARSED_MODEL}")
            shift
            ;;
        --QA=*)
            parse_role_arg "$1"
            TEAM_MEMBERS+=("QA:qa:${PARSED_MARKDOWN}:${PARSED_AGENT}:${PARSED_MODEL}")
            shift
            ;;
        --Requirements=*)
            parse_role_arg "$1"
            TEAM_MEMBERS+=("REQUIREMENTS:requirements:${PARSED_MARKDOWN}:${PARSED_AGENT}:${PARSED_MODEL}")
            shift
            ;;
        --DevOps=*)
            parse_role_arg "$1"
            TEAM_MEMBERS+=("DEVOPS:devops:${PARSED_MARKDOWN}:${PARSED_AGENT}:${PARSED_MODEL}")
            shift
            ;;
        --DataScience=*)
            parse_role_arg "$1"
            TEAM_MEMBERS+=("DATASCIENCE:datascience:${PARSED_MARKDOWN}:${PARSED_AGENT}:${PARSED_MODEL}")
            shift
            ;;
        --CodeReviewer=*)
            parse_role_arg "$1"
            TEAM_MEMBERS+=("REVIEWER:reviewer:${PARSED_MARKDOWN}:${PARSED_AGENT}:${PARSED_MODEL}")
            shift
            ;;
        --Guidance=*)
            GUIDANCE_FILES+=("${1#*=}")
            shift
            ;;
        --continue)
            CONTINUE_SESSION=true
            shift
            ;;
        --use-ccr)
            USE_CCR=true
            shift
            ;;
        --ForceCleanup)
            FORCE_CLEANUP=true
            shift
            ;;
        -h|--help)
            echo "Usage: launch-dev-team.sh [OPTIONS] <project-directory>"
            echo ""
            echo "Options:"
            echo "  --Architect=<agent>[:<model>]@<markdown>    AI agent and persona file for Architect"
            echo "  --Developer=<agent>[:<model>]@<markdown>    Add a developer (can be repeated)"
            echo "  --UX=<agent>[:<model>]@<markdown>           Add UX specialist"
            echo "  --Security=<agent>[:<model>]@<markdown>     Add Security specialist"
            echo "  --Cloud=<agent>[:<model>]@<markdown>        Add Cloud engineer"
            echo "  --QA=<agent>[:<model>]@<markdown>           Add QA/Testing specialist"
            echo "  --Requirements=<agent>[:<model>]@<markdown> Add Requirements Analyst"
            echo "  --DevOps=<agent>[:<model>]@<markdown>       Add DevOps Engineer"
            echo "  --DataScience=<agent>[:<model>]@<markdown>  Add Data Scientist"
            echo "  --CodeReviewer=<agent>[:<model>]@<markdown> Add Code Reviewer"
            echo "  --Guidance=<markdown>                       Add guidance file (can be repeated)"
            echo "  --use-ccr                         Route Claude agents through claude-code-router (ccr)"
            echo "  --continue                        Continue previous session for each agent"
            echo "  --ForceCleanup                    Force remove all worktrees and branches, then exit"
            echo "  -h, --help                        Show this help message"
            echo ""
            echo "Agents: claude, gemini, codex"
            echo "Models (optional):"
            echo "  Claude: opus-4-6, sonnet-4-5, haiku-4-5 (default: sonnet-4-5)"
            echo "  Gemini: gemini-2.0-flash-exp, gemini-1.5-pro, etc. (default: per gemini CLI)"
            echo "  Codex:  gpt-4, gpt-3.5-turbo, etc. (default: per codex CLI)"
            echo ""
            echo "The <markdown> path specifies the persona/instructions file for each role."
            echo "Paths can be absolute or relative to the project directory."
            echo ""
            echo "Persona files are copied to .swarm/Personas/ and referenced in CLAUDE.md."
            echo "Guidance files are copied to .swarm/Guidance/ and referenced in CLAUDE.md."
            echo ""
            echo "Example:"
            echo "  launch-dev-team.sh \\"
            echo "    --Guidance=docs/architecture.md \\"
            echo "    --Guidance=docs/tdd-process.md \\"
            echo "    --Architect=claude:sonnet-4-5@architect.md \\"
            echo "    --Developer=claude:opus-4-6@backend-dev.md \\"
            echo "    --Developer=gemini:gemini-2.0-flash-exp@frontend-dev.md \\"
            echo "    --QA=claude@qa-tester.md \\"
            echo "    ~/projects/myapp"
            echo ""
            echo "This will:"
            echo "  - Copy guidance files to .swarm/Guidance/ and reference in CLAUDE.md"
            echo "  - Copy persona files to .swarm/Personas/ and reference in CLAUDE.md"
            echo "  - Create worktrees in .worktrees/ for each developer with their persona"
            echo ""
            echo "Sandbox Permissions by Role:"
            echo "  Architect:     Full project access, all tools, web access"
            echo "  Developer:     Own worktree, git/npm/node/python, no web"
            echo "  UX:            Own worktree, git/npm/node, web access"
            echo "  Security:      Own worktree + read main, security scan tools, no web"
            echo "  Cloud:         Own worktree, git/aws/terraform/docker, web access"
            echo "  QA:            Own worktree + read main, test runners, no web"
            echo "  Requirements:  Read-only main project, documentation tools, web access"
            echo "  DevOps:        Own worktree, CI/CD tools, docker/k8s, web access"
            echo "  DataScience:   Own worktree, python/jupyter/data tools, web access"
            echo "  CodeReviewer:  Read-only all worktrees, git/diff tools, no web"
            exit 0
            ;;
        -*)
            echo "Unknown option: $1" >&2
            echo "Use -h for help" >&2
            exit 1
            ;;
        *)
            PROJECT_DIR="$1"
            shift
            ;;
    esac
done

# Validate required arguments
if [[ -z "$PROJECT_DIR" ]]; then
    echo "Error: Project directory is required" >&2
    echo "Usage: launch-dev-team.sh [OPTIONS] <project-directory>" >&2
    exit 1
fi

# Resolve project directory to absolute path (needed for cleanup)
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
PROJECT_NAME="$(basename "$PROJECT_DIR")"
WORKTREES_DIR="$PROJECT_DIR/.worktrees"

# =============================================================================
# Force Cleanup Mode
# =============================================================================
if [[ "$FORCE_CLEANUP" == true ]]; then
    echo "Force cleanup mode - removing all worktrees and branches..."
    echo "Project: $PROJECT_NAME"
    echo "Directory: $PROJECT_DIR"
    echo ""

    # Kill tmux session if it exists
    if tmux has-session -t dev 2>/dev/null; then
        echo "Killing 'dev' tmux session..."
        tmux kill-session -t dev
    fi

    # Find and remove all worktrees in .worktrees/
    echo "Removing worktrees..."
    if [[ -d "$WORKTREES_DIR" ]]; then
        for worktree_dir in "$WORKTREES_DIR"/*/; do
            if [[ -d "$worktree_dir" ]]; then
                worktree_name=$(basename "$worktree_dir")
                echo "  Removing worktree: $worktree_name"
                git -C "$PROJECT_DIR" worktree remove --force "$worktree_dir" 2>/dev/null || rm -rf "$worktree_dir"
            fi
        done
        rmdir "$WORKTREES_DIR" 2>/dev/null || true
    fi

    # Prune stale worktree references
    echo "Pruning stale worktree references..."
    git -C "$PROJECT_DIR" worktree prune

    # Remove dev/* branches
    echo "Removing dev/* branches..."
    git -C "$PROJECT_DIR" for-each-ref --format='%(refname:short)' refs/heads/dev/ | while read branch; do
        echo "  Deleting branch: $branch"
        git -C "$PROJECT_DIR" branch -D "$branch" 2>/dev/null || true
    done

    # Clean up generated files in worktrees
    echo "Cleaning up generated files in worktrees..."
    if [[ -d "$WORKTREES_DIR" ]]; then
        for worktree_dir in "$WORKTREES_DIR"/*/; do
            if [[ -d "$worktree_dir" ]]; then
                echo "  Cleaning: $(basename "$worktree_dir")"
                rm -f "$worktree_dir/CLAUDE.md"
                rm -rf "$worktree_dir/.claude/settings.local.json"
                rm -rf "$worktree_dir/.swarm/Personas"
                rm -rf "$worktree_dir/.swarm/Guidance"
                rm -rf "$worktree_dir/.gemini"
                rm -rf "$worktree_dir/.codex"
            fi
        done
    fi

    # Clean up generated files in main project
    echo "Cleaning up generated files in main project..."
    rm -f "$PROJECT_DIR/CLAUDE.md"
    rm -rf "$PROJECT_DIR/.claude/settings.local.json"
    rm -rf "$PROJECT_DIR/.swarm/Personas"
    rm -rf "$PROJECT_DIR/.swarm/Guidance"
    rm -rf "$PROJECT_DIR/.gemini"
    rm -rf "$PROJECT_DIR/.codex"

    echo ""
    echo "Cleanup complete."
    exit 0
fi

if [[ -z "$ARCHITECT_AGENT" || -z "$ARCHITECT_MARKDOWN" ]]; then
    echo "Error: Architect is required (e.g., --Architect=claude@persona.md)" >&2
    exit 1
fi

if [[ ${#TEAM_MEMBERS[@]} -eq 0 ]]; then
    echo "Error: At least one team member is required (e.g., --Developer=claude@persona.md)" >&2
    exit 1
fi

# Validate agent names
validate_agent() {
    local agent="$1"
    case "$agent" in
        claude|gemini|codex) return 0 ;;
        *)
            echo "Error: Invalid agent '$agent'. Must be one of: claude, gemini, codex" >&2
            exit 1
            ;;
    esac
}

validate_agent "$ARCHITECT_AGENT"
for MEMBER_SPEC in "${TEAM_MEMBERS[@]}"; do
    # Extract agent (4th field) from name:role:markdown:agent:model
    TEMP="${MEMBER_SPEC#*:}"    # Remove name
    TEMP="${TEMP#*:}"            # Remove role
    TEMP="${TEMP#*:}"            # Remove markdown
    AGENT="${TEMP%%:*}"          # Get agent (before model)
    validate_agent "$AGENT"
done

echo "Setting up multi-agent development environment..."
echo "Project: $PROJECT_NAME"
echo "Directory: $PROJECT_DIR"
if [[ ${#GUIDANCE_FILES[@]} -gt 0 ]]; then
    echo "Guidance files:"
    for guidance in "${GUIDANCE_FILES[@]}"; do
        echo "  - $guidance"
    done
fi
if [[ -n "$ARCHITECT_MODEL" ]]; then
    echo "Architect: $ARCHITECT_AGENT:$ARCHITECT_MODEL using $ARCHITECT_MARKDOWN"
else
    echo "Architect: $ARCHITECT_AGENT using $ARCHITECT_MARKDOWN"
fi
echo "Team members:"
for MEMBER_SPEC in "${TEAM_MEMBERS[@]}"; do
    # Parse name:role:markdown:agent:model format
    MEMBER_NAME="${MEMBER_SPEC%%:*}"
    TEMP="${MEMBER_SPEC#*:}"
    MEMBER_ROLE="${TEMP%%:*}"
    TEMP="${TEMP#*:}"
    MEMBER_MARKDOWN="${TEMP%%:*}"
    TEMP="${TEMP#*:}"
    MEMBER_AGENT="${TEMP%%:*}"
    MEMBER_MODEL="${TEMP#*:}"
    if [[ -n "$MEMBER_MODEL" ]]; then
        echo "  - $MEMBER_NAME ($MEMBER_ROLE) using $MEMBER_AGENT:$MEMBER_MODEL with $MEMBER_MARKDOWN"
    else
        echo "  - $MEMBER_NAME ($MEMBER_ROLE) using $MEMBER_AGENT with $MEMBER_MARKDOWN"
    fi
done

# Ensure we're in a git repository
if ! git -C "$PROJECT_DIR" rev-parse --git-dir > /dev/null 2>&1; then
    echo "Error: $PROJECT_DIR is not a git repository" >&2
    exit 1
fi

# Get the current branch to use as base for worktrees
BASE_BRANCH=$(git -C "$PROJECT_DIR" branch --show-current)
echo "Base branch: $BASE_BRANCH"

# =============================================================================
# Claude Code Sandbox Configuration
# Uses .claude/settings.local.json
# Docs: https://docs.anthropic.com/en/docs/claude-code
# =============================================================================
create_claude_sandbox() {
    local target_dir="$1"
    local role="$2"
    local worktree_path="$3"

    mkdir -p "$target_dir/.claude"

    local settings_file="$target_dir/.claude/settings.local.json"

    case "$role" in
        architect)
            cat > "$settings_file" << EOF
{
  "permissions": {
    "allow": [
      "Read",
      "Write",
      "Edit",
      "Bash",
      "WebFetch",
      "WebSearch",
      "Grep",
      "Glob"
    ],
    "deny": []
  },
  "sandbox": {
    "readPaths": ["$PROJECT_DIR"],
    "writePaths": ["$PROJECT_DIR"],
    "allowedCommands": ["git", "npm", "node", "python", "pytest", "aws", "terraform", "docker", "gh", "curl"],
    "networkAccess": true
  }
}
EOF
            ;;
        developer)
            cat > "$settings_file" << EOF
{
  "permissions": {
    "allow": [
      "Read",
      "Write",
      "Edit",
      "Bash",
      "Grep",
      "Glob"
    ],
    "deny": [
      "WebFetch",
      "WebSearch"
    ]
  },
  "sandbox": {
    "readPaths": ["$worktree_path", "$PROJECT_DIR/shared", "$PROJECT_DIR/libs"],
    "writePaths": ["$worktree_path"],
    "allowedCommands": ["git", "npm", "node", "npx", "python", "pytest", "pip", "make", "cargo", "go"],
    "networkAccess": false
  }
}
EOF
            ;;
        ux)
            cat > "$settings_file" << EOF
{
  "permissions": {
    "allow": [
      "Read",
      "Write",
      "Edit",
      "Bash",
      "WebFetch",
      "WebSearch",
      "Grep",
      "Glob"
    ],
    "deny": []
  },
  "sandbox": {
    "readPaths": ["$worktree_path", "$PROJECT_DIR/shared", "$PROJECT_DIR/assets", "$PROJECT_DIR/design"],
    "writePaths": ["$worktree_path"],
    "allowedCommands": ["git", "npm", "node", "npx", "figma", "storybook"],
    "networkAccess": true,
    "allowedDomains": ["fonts.google.com", "unpkg.com", "cdnjs.com", "figma.com", "dribbble.com"]
  }
}
EOF
            ;;
        security)
            cat > "$settings_file" << EOF
{
  "permissions": {
    "allow": [
      "Read",
      "Write",
      "Edit",
      "Bash",
      "Grep",
      "Glob"
    ],
    "deny": [
      "WebFetch",
      "WebSearch"
    ]
  },
  "sandbox": {
    "readPaths": ["$worktree_path", "$PROJECT_DIR"],
    "writePaths": ["$worktree_path"],
    "allowedCommands": ["git", "npm", "node", "semgrep", "bandit", "trivy", "snyk", "gitleaks", "trufflehog", "safety"],
    "networkAccess": false
  }
}
EOF
            ;;
        cloud)
            cat > "$settings_file" << EOF
{
  "permissions": {
    "allow": [
      "Read",
      "Write",
      "Edit",
      "Bash",
      "WebFetch",
      "Grep",
      "Glob"
    ],
    "deny": [
      "WebSearch"
    ]
  },
  "sandbox": {
    "readPaths": ["$worktree_path", "$PROJECT_DIR/infrastructure", "$PROJECT_DIR/deploy", "$HOME/.aws", "$HOME/.config/gcloud", "$HOME/.azure"],
    "writePaths": ["$worktree_path"],
    "allowedCommands": ["git", "aws", "gcloud", "gsutil", "az", "terraform", "terragrunt", "docker", "kubectl", "helm", "pulumi", "cdk", "sam"],
    "networkAccess": true,
    "allowedDomains": ["amazonaws.com", "aws.amazon.com", "googleapis.com", "google.cloud", "azure.com", "microsoft.com", "registry.terraform.io", "hub.docker.com"]
  }
}
EOF
            ;;
        qa)
            cat > "$settings_file" << EOF
{
  "permissions": {
    "allow": [
      "Read",
      "Write",
      "Edit",
      "Bash",
      "Grep",
      "Glob"
    ],
    "deny": [
      "WebFetch",
      "WebSearch"
    ]
  },
  "sandbox": {
    "readPaths": ["$worktree_path", "$PROJECT_DIR"],
    "writePaths": ["$worktree_path"],
    "allowedCommands": ["git", "npm", "node", "npx", "pytest", "jest", "mocha", "cypress", "playwright", "vitest", "coverage"],
    "networkAccess": false
  }
}
EOF
            ;;
        requirements)
            cat > "$settings_file" << EOF
{
  "permissions": {
    "allow": [
      "Read",
      "WebFetch",
      "WebSearch",
      "Grep",
      "Glob"
    ],
    "deny": [
      "Write",
      "Edit",
      "Bash"
    ]
  },
  "sandbox": {
    "readPaths": ["$PROJECT_DIR"],
    "writePaths": ["$worktree_path/docs", "$worktree_path/requirements"],
    "allowedCommands": ["git", "pandoc", "markdown"],
    "networkAccess": true
  }
}
EOF
            ;;
        devops)
            cat > "$settings_file" << EOF
{
  "permissions": {
    "allow": [
      "Read",
      "Write",
      "Edit",
      "Bash",
      "WebFetch",
      "Grep",
      "Glob"
    ],
    "deny": [
      "WebSearch"
    ]
  },
  "sandbox": {
    "readPaths": ["$worktree_path", "$PROJECT_DIR/.github", "$PROJECT_DIR/infrastructure", "$HOME/.docker"],
    "writePaths": ["$worktree_path"],
    "allowedCommands": ["git", "docker", "docker-compose", "kubectl", "helm", "gh", "act", "make", "ansible", "vagrant"],
    "networkAccess": true,
    "allowedDomains": ["github.com", "hub.docker.com", "registry.npmjs.org"]
  }
}
EOF
            ;;
        datascience)
            cat > "$settings_file" << EOF
{
  "permissions": {
    "allow": [
      "Read",
      "Write",
      "Edit",
      "Bash",
      "WebFetch",
      "WebSearch",
      "Grep",
      "Glob"
    ],
    "deny": []
  },
  "sandbox": {
    "readPaths": ["$worktree_path", "$PROJECT_DIR/data", "$PROJECT_DIR/models", "$PROJECT_DIR/notebooks"],
    "writePaths": ["$worktree_path"],
    "allowedCommands": ["git", "python", "pip", "conda", "jupyter", "ipython", "pandas", "numpy", "dvc", "mlflow"],
    "networkAccess": true,
    "allowedDomains": ["pypi.org", "anaconda.org", "huggingface.co", "kaggle.com"]
  }
}
EOF
            ;;
        reviewer)
            cat > "$settings_file" << EOF
{
  "permissions": {
    "allow": [
      "Read",
      "Grep",
      "Glob"
    ],
    "deny": [
      "Write",
      "Edit",
      "Bash",
      "WebFetch",
      "WebSearch"
    ]
  },
  "sandbox": {
    "readPaths": ["$PROJECT_DIR"],
    "writePaths": [],
    "allowedCommands": ["git", "diff", "gh"],
    "networkAccess": false
  }
}
EOF
            ;;
    esac

    echo "  Created Claude sandbox: $settings_file"
}

# =============================================================================
# Gemini CLI Sandbox Configuration
# Uses .gemini/settings.json with tools.sandbox and environment variables
# Docs: https://github.com/google-gemini/gemini-cli/blob/main/docs/cli/sandbox.md
#
# Seatbelt profiles (macOS):
#   - permissive-open: Write restrictions, network allowed (default)
#   - permissive-closed: Write restrictions, no network
#   - restrictive-open: Strict restrictions, network allowed
#   - restrictive-closed: Maximum restrictions
# =============================================================================
create_gemini_sandbox() {
    local target_dir="$1"
    local role="$2"
    local worktree_path="$3"

    mkdir -p "$target_dir/.gemini"

    local settings_file="$target_dir/.gemini/settings.json"
    local env_file="$target_dir/.gemini/.env"

    # Determine Seatbelt profile based on role's network needs
    local seatbelt_profile="permissive-closed"  # Default: no network
    case "$role" in
        architect|ux|cloud|requirements|devops|datascience) seatbelt_profile="permissive-open" ;;  # Network allowed
        developer|security|qa|reviewer) seatbelt_profile="permissive-closed" ;;  # No network
    esac

    # Create settings.json with sandbox enabled
    case "$role" in
        architect)
            cat > "$settings_file" << EOF
{
  "tools": {
    "sandbox": true,
    "shell": {
      "allowedCommands": ["git", "npm", "node", "python", "pytest", "aws", "terraform", "docker", "gh", "curl", "tmux"]
    }
  },
  "general": {
    "projectRoot": "$PROJECT_DIR"
  }
}
EOF
            ;;
        developer)
            cat > "$settings_file" << EOF
{
  "tools": {
    "sandbox": true,
    "shell": {
      "allowedCommands": ["git", "npm", "node", "npx", "python", "pytest", "pip", "make", "cargo", "go"]
    }
  },
  "general": {
    "projectRoot": "$worktree_path"
  }
}
EOF
            ;;
        ux)
            cat > "$settings_file" << EOF
{
  "tools": {
    "sandbox": true,
    "shell": {
      "allowedCommands": ["git", "npm", "node", "npx", "figma", "storybook"]
    }
  },
  "general": {
    "projectRoot": "$worktree_path"
  }
}
EOF
            ;;
        security)
            cat > "$settings_file" << EOF
{
  "tools": {
    "sandbox": true,
    "shell": {
      "allowedCommands": ["git", "npm", "node", "semgrep", "bandit", "trivy", "snyk", "gitleaks", "trufflehog", "safety"]
    }
  },
  "general": {
    "projectRoot": "$worktree_path"
  }
}
EOF
            ;;
        cloud)
            cat > "$settings_file" << EOF
{
  "tools": {
    "sandbox": true,
    "shell": {
      "allowedCommands": ["git", "aws", "gcloud", "gsutil", "az", "terraform", "terragrunt", "docker", "kubectl", "helm", "pulumi", "cdk", "sam"]
    }
  },
  "general": {
    "projectRoot": "$worktree_path"
  }
}
EOF
            ;;
        qa)
            cat > "$settings_file" << EOF
{
  "tools": {
    "sandbox": true,
    "shell": {
      "allowedCommands": ["git", "npm", "node", "npx", "pytest", "jest", "mocha", "cypress", "playwright", "vitest", "coverage"]
    }
  },
  "general": {
    "projectRoot": "$worktree_path"
  }
}
EOF
            ;;
        requirements)
            cat > "$settings_file" << EOF
{
  "tools": {
    "sandbox": true,
    "shell": {
      "allowedCommands": ["git", "pandoc", "markdown"]
    }
  },
  "general": {
    "projectRoot": "$worktree_path"
  }
}
EOF
            ;;
        devops)
            cat > "$settings_file" << EOF
{
  "tools": {
    "sandbox": true,
    "shell": {
      "allowedCommands": ["git", "docker", "docker-compose", "kubectl", "helm", "gh", "act", "make", "ansible", "vagrant"]
    }
  },
  "general": {
    "projectRoot": "$worktree_path"
  }
}
EOF
            ;;
        datascience)
            cat > "$settings_file" << EOF
{
  "tools": {
    "sandbox": true,
    "shell": {
      "allowedCommands": ["git", "python", "pip", "conda", "jupyter", "ipython", "pandas", "numpy", "dvc", "mlflow"]
    }
  },
  "general": {
    "projectRoot": "$worktree_path"
  }
}
EOF
            ;;
        reviewer)
            cat > "$settings_file" << EOF
{
  "tools": {
    "sandbox": true,
    "shell": {
      "allowedCommands": ["git", "diff", "gh"]
    }
  },
  "general": {
    "projectRoot": "$worktree_path"
  }
}
EOF
            ;;
    esac

    # Create .env file with Seatbelt profile for macOS sandboxing
    cat > "$env_file" << EOF
# Gemini CLI sandbox environment
GEMINI_SANDBOX=true
SEATBELT_PROFILE=$seatbelt_profile
EOF

    echo "  Created Gemini sandbox: $settings_file"
    echo "  Created Gemini env: $env_file (profile: $seatbelt_profile)"
}

# =============================================================================
# OpenAI Codex CLI Sandbox Configuration
# Uses .codex/config.toml (TOML format)
# Docs: https://developers.openai.com/codex/config-reference/
#
# Sandbox modes:
#   - read-only: No write operations allowed
#   - workspace-write: Writes permitted in designated directories
#   - danger-full-access: Unrestricted (use cautiously)
#
# Approval policies:
#   - never: Execute without interruption
#   - on-request: Wait for explicit confirmation
#   - on-failure: Approve only after errors
#   - untrusted: Pause in unverified projects
# =============================================================================
create_codex_sandbox() {
    local target_dir="$1"
    local role="$2"
    local worktree_path="$3"

    mkdir -p "$target_dir/.codex"

    local config_file="$target_dir/.codex/config.toml"

    case "$role" in
        architect)
            cat > "$config_file" << EOF
# Codex CLI configuration for Architect role
# Full access for project coordination

[sandbox]
mode = "workspace-write"
network_access = true

[sandbox.writable_roots]
paths = ["$PROJECT_DIR"]

[approval]
policy = "never"

[shell_environment_policy]
inherit = "core"
set = { PROJECT_ROOT = "$PROJECT_DIR" }
EOF
            ;;
        developer)
            cat > "$config_file" << EOF
# Codex CLI configuration for Developer role
# Restricted to own worktree, no network

[sandbox]
mode = "workspace-write"
network_access = false
exclude_slash_tmp = false

[sandbox.writable_roots]
paths = ["$worktree_path"]

[approval]
policy = "never"

[shell_environment_policy]
inherit = "core"
set = { PROJECT_ROOT = "$worktree_path" }
EOF
            ;;
        ux)
            cat > "$config_file" << EOF
# Codex CLI configuration for UX role
# Own worktree with network access for design resources

[sandbox]
mode = "workspace-write"
network_access = true
exclude_slash_tmp = false

[sandbox.writable_roots]
paths = ["$worktree_path"]

[approval]
policy = "never"

[shell_environment_policy]
inherit = "core"
set = { PROJECT_ROOT = "$worktree_path" }
EOF
            ;;
        security)
            cat > "$config_file" << EOF
# Codex CLI configuration for Security role
# Read access to main project, write only to worktree, no network

[sandbox]
mode = "workspace-write"
network_access = true
exclude_slash_tmp = true

[sandbox.writable_roots]
paths = ["$worktree_path"]

[approval]
policy = "never"

[shell_environment_policy]
inherit = "core"
exclude = ["*KEY*", "*SECRET*", "*TOKEN*", "*PASSWORD*", "*CREDENTIAL*"]
set = { PROJECT_ROOT = "$worktree_path", MAIN_PROJECT = "$PROJECT_DIR" }
EOF
            ;;
        cloud)
            cat > "$config_file" << EOF
# Codex CLI configuration for Cloud role
# Network access for AWS/GCP/Azure cloud operations

[sandbox]
mode = "workspace-write"
network_access = true
exclude_slash_tmp = false

[sandbox.writable_roots]
paths = ["$worktree_path"]

[approval]
policy = "never"

[shell_environment_policy]
inherit = "all"
include_only = ["HOME", "USER", "PATH", "AWS_*", "GOOGLE_*", "GCLOUD_*", "CLOUDSDK_*", "AZURE_*", "ARM_*", "DOCKER_*", "KUBECONFIG", "TERRAFORM_*"]
set = { PROJECT_ROOT = "$worktree_path" }
EOF
            ;;
        qa)
            cat > "$config_file" << EOF
# Codex CLI configuration for QA role
# Testing tools, read access to main project, no network

[sandbox]
mode = "workspace-write"
network_access = false
exclude_slash_tmp = false

[sandbox.writable_roots]
paths = ["$worktree_path"]

[approval]
policy = "never"

[shell_environment_policy]
inherit = "core"
set = { PROJECT_ROOT = "$worktree_path", MAIN_PROJECT = "$PROJECT_DIR" }
EOF
            ;;
        requirements)
            cat > "$config_file" << EOF
# Codex CLI configuration for Requirements Analyst role
# Read-only access to project, documentation tools, network for research

[sandbox]
mode = "read-only"
network_access = true
exclude_slash_tmp = false

[sandbox.writable_roots]
paths = ["$worktree_path/docs", "$worktree_path/requirements"]

[approval]
policy = "never"

[shell_environment_policy]
inherit = "core"
set = { PROJECT_ROOT = "$PROJECT_DIR" }
EOF
            ;;
        devops)
            cat > "$config_file" << EOF
# Codex CLI configuration for DevOps role
# CI/CD tools, docker, kubernetes, network access

[sandbox]
mode = "workspace-write"
network_access = true
exclude_slash_tmp = false

[sandbox.writable_roots]
paths = ["$worktree_path"]

[approval]
policy = "never"

[shell_environment_policy]
inherit = "all"
include_only = ["HOME", "USER", "PATH", "DOCKER_*", "KUBECONFIG", "CI", "GITHUB_*"]
set = { PROJECT_ROOT = "$worktree_path" }
EOF
            ;;
        datascience)
            cat > "$config_file" << EOF
# Codex CLI configuration for Data Science role
# Python/Jupyter tools, data access, network for packages

[sandbox]
mode = "workspace-write"
network_access = true
exclude_slash_tmp = false

[sandbox.writable_roots]
paths = ["$worktree_path"]

[approval]
policy = "never"

[shell_environment_policy]
inherit = "core"
set = { PROJECT_ROOT = "$worktree_path", PYTHONPATH = "$worktree_path" }
EOF
            ;;
        reviewer)
            cat > "$config_file" << EOF
# Codex CLI configuration for Code Reviewer role
# Read-only access to all project files, no network

[sandbox]
mode = "read-only"
network_access = false
exclude_slash_tmp = true

[sandbox.writable_roots]
paths = []

[approval]
policy = "never"

[shell_environment_policy]
inherit = "core"
set = { PROJECT_ROOT = "$PROJECT_DIR" }
EOF
            ;;
    esac

    echo "  Created Codex sandbox: $config_file"
}

# =============================================================================
# CLI Launch Commands
# =============================================================================
get_cli_command() {
    local agent="$1"
    local role="$2"
    local model="$3"
    local continue_flag=""
    local model_flag=""

    # Add model flag if specified
    if [[ -n "$model" ]]; then
        model_flag=" --model $model"
    fi

    case "$agent" in
        claude)
            # Claude Code CLI: --dangerously-skip-permissions for unattended operation
            if [[ "$CONTINUE_SESSION" == true ]]; then
                continue_flag=" --continue"
            fi
            if [[ "$USE_CCR" == true ]]; then
                echo "ccr code --dangerously-skip-permissions$model_flag$continue_flag"
            else
                echo "claude --dangerously-skip-permissions$model_flag$continue_flag"
            fi
            ;;
        gemini)
            # Gemini CLI: --sandbox enables sandboxing, --yolo auto-approves
            # Settings in .gemini/settings.json and .gemini/.env configure the sandbox
            if [[ "$CONTINUE_SESSION" == true ]]; then
                continue_flag=" --resume"
            fi
            echo "gemini --sandbox --yolo$model_flag$continue_flag"
            ;;
        codex)
            # Codex CLI: --full-auto for workspace-write + on-request approval
            # But we want unattended, so use config.toml with approval.policy = "never"
            # Codex does not support continue/resume
            echo "codex --dangerously-bypass-approvals-and-sandbox$model_flag"
            ;;
    esac
}

# =============================================================================
# CLAUDE.md Management
# Writes per-member session instructions referencing .swarm/ files
# =============================================================================

# Session instructions marker - used to find/replace the instructions block
SESSION_INSTRUCTIONS_START="<!-- SESSION-INSTRUCTIONS-START -->"
SESSION_INSTRUCTIONS_END="<!-- SESSION-INSTRUCTIONS-END -->"

# Generate session instructions block
# Args: $1=persona_file (original source path), $2...=guidance_files (relative paths)
generate_session_instructions() {
    local persona_file="$1"
    shift
    local guidance_files=("$@")

    cat << 'INSTRUCTIONS_HEADER'
<!-- SESSION-INSTRUCTIONS-START -->
# Session Management

## On Session Start
At the beginning of each new session, read the following files to understand your role and project context:

INSTRUCTIONS_HEADER

    # List guidance files
    if [[ ${#guidance_files[@]} -gt 0 ]]; then
        echo "### Guidance"
        for gfile in "${guidance_files[@]}"; do
            echo "- \`.swarm/Guidance/$gfile\`"
        done
        echo ""
    fi

    # List persona file
    echo "### Persona"
    echo "- \`$persona_file\`"
    echo ""

    cat << 'INSTRUCTIONS_FOOTER'
## On Context Compaction
When context is being compacted, re-read the guidance and persona files listed above to maintain full context of your role and project standards.
<!-- SESSION-INSTRUCTIONS-END -->

INSTRUCTIONS_FOOTER
}

# Remove existing session instructions from CLAUDE.md
# Args: $1=claude_md_path
remove_session_instructions() {
    local claude_md="$1"

    if [[ -f "$claude_md" ]]; then
        # Remove everything between (and including) the markers
        sed -e "/$SESSION_INSTRUCTIONS_START/,/$SESSION_INSTRUCTIONS_END/d" "$claude_md" > "$claude_md.tmp"
        mv "$claude_md.tmp" "$claude_md"
    fi
}


# Write session instructions to CLAUDE.md
# Args: $1=target_dir
# Uses: CURRENT_PERSONA, CURRENT_GUIDANCE_FILES (set during main setup)
write_session_instructions() {
    local target_dir="$1"
    local claude_md="$target_dir/CLAUDE.md"

    # Ensure CLAUDE.md exists
    touch "$claude_md"

    # Remove any existing session instructions
    remove_session_instructions "$claude_md"

    # Generate new instructions and prepend to CLAUDE.md
    generate_session_instructions "$CURRENT_PERSONA" "${CURRENT_GUIDANCE_FILES[@]}" | cat - "$claude_md" > "$claude_md.tmp"
    mv "$claude_md.tmp" "$claude_md"
    echo "  Added session instructions to CLAUDE.md"
}

# =============================================================================
# Main Setup
# =============================================================================

# --- Resolve all persona and guidance file paths ---
echo ""
echo "Resolving persona and guidance files..."

# Resolve architect markdown path
# Priority: absolute paths, then ~/.claude/personas/, then relative to project
ARCHITECT_MARKDOWN="${ARCHITECT_MARKDOWN/#\~/$HOME}"
if [[ "$ARCHITECT_MARKDOWN" = /* ]]; then
    ARCHITECT_ROLE_FILE="$ARCHITECT_MARKDOWN"
elif [[ "$ARCHITECT_MARKDOWN" != */* ]]; then
    ARCHITECT_ROLE_FILE="$HOME/.claude/personas/$ARCHITECT_MARKDOWN"
else
    ARCHITECT_ROLE_FILE="$PROJECT_DIR/$ARCHITECT_MARKDOWN"
fi

if [[ ! -f "$ARCHITECT_ROLE_FILE" ]]; then
    echo "  Error: Persona file not found: $ARCHITECT_ROLE_FILE" >&2
    exit 1
fi
ARCHITECT_PERSONA_FILENAME=$(basename "$ARCHITECT_ROLE_FILE")
echo "  Architect persona: $ARCHITECT_PERSONA_FILENAME"

# Resolve all member markdown paths upfront
declare -a RESOLVED_ROLE_FILES=()
declare -a PERSONA_FILENAMES=()
for MEMBER_SPEC in "${TEAM_MEMBERS[@]}"; do
    MEMBER_NAME="${MEMBER_SPEC%%:*}"
    TEMP="${MEMBER_SPEC#*:}"
    TEMP="${TEMP#*:}"
    MEMBER_MARKDOWN="${TEMP%%:*}"

    MEMBER_MARKDOWN="${MEMBER_MARKDOWN/#\~/$HOME}"
    if [[ "$MEMBER_MARKDOWN" = /* ]]; then
        ROLE_FILE="$MEMBER_MARKDOWN"
    elif [[ "$MEMBER_MARKDOWN" != */* ]]; then
        ROLE_FILE="$HOME/.claude/tmux_personas/$MEMBER_MARKDOWN"
    else
        ROLE_FILE="$PROJECT_DIR/$MEMBER_MARKDOWN"
    fi

    if [[ ! -f "$ROLE_FILE" ]]; then
        echo "  Error: Persona file not found for $MEMBER_NAME: $ROLE_FILE" >&2
        exit 1
    fi
    RESOLVED_ROLE_FILES+=("$ROLE_FILE")
    PERSONA_FILENAMES+=("$(basename "$ROLE_FILE")")
    echo "  $MEMBER_NAME persona: $(basename "$ROLE_FILE")"
done

# Resolve guidance files
declare -a RESOLVED_GUIDANCE=()
for guidance in "${GUIDANCE_FILES[@]}"; do
    guidance="${guidance/#\~/$HOME}"
    if [[ "$guidance" = /* ]]; then
        resolved="$guidance"
    else
        resolved="$PROJECT_DIR/$guidance"
    fi
    if [[ ! -f "$resolved" ]]; then
        echo "  Error: Guidance file not found: $resolved" >&2
        exit 1
    fi
    RESOLVED_GUIDANCE+=("$resolved")
    echo "  Guidance: $(basename "$resolved")"
done

# --- Copy ALL persona and guidance files to $PROJECT_DIR/.swarm/ ---
echo ""
echo "Setting up .swarm directory..."

mkdir -p "$PROJECT_DIR/.swarm/Personas"

# Copy architect persona
cp "$ARCHITECT_ROLE_FILE" "$PROJECT_DIR/.swarm/Personas/$ARCHITECT_PERSONA_FILENAME"
echo "  Copied persona: $ARCHITECT_PERSONA_FILENAME"

# Copy all member personas
for i in "${!RESOLVED_ROLE_FILES[@]}"; do
    filename="${PERSONA_FILENAMES[$i]}"
    cp "${RESOLVED_ROLE_FILES[$i]}" "$PROJECT_DIR/.swarm/Personas/$filename"
    echo "  Copied persona: $filename"
done

# Copy guidance files
CURRENT_GUIDANCE_FILES=()
if [[ ${#RESOLVED_GUIDANCE[@]} -gt 0 ]]; then
    mkdir -p "$PROJECT_DIR/.swarm/Guidance"
    for resolved in "${RESOLVED_GUIDANCE[@]}"; do
        filename=$(basename "$resolved")
        cp "$resolved" "$PROJECT_DIR/.swarm/Guidance/$filename"
        echo "  Copied guidance: $filename"
        CURRENT_GUIDANCE_FILES+=("$filename")
    done
fi

# --- Commit .swarm/ to git so worktrees inherit the files ---
echo ""
echo "Committing .swarm/ to git..."
git -C "$PROJECT_DIR" add .swarm/
if ! git -C "$PROJECT_DIR" diff --cached --quiet -- .swarm/; then
    git -C "$PROJECT_DIR" commit -m "Update .swarm persona and guidance files"
    echo "  Committed .swarm/ to $BASE_BRANCH"
else
    echo "  .swarm/ already up to date in git"
fi

# --- Setup Architect (main project directory) ---
echo ""
echo "Setting up Architect ($ARCHITECT_AGENT)..."
CURRENT_PERSONA=".swarm/Personas/$ARCHITECT_PERSONA_FILENAME"
write_session_instructions "$PROJECT_DIR"

case "$ARCHITECT_AGENT" in
    claude) create_claude_sandbox "$PROJECT_DIR" "architect" "$PROJECT_DIR" ;;
    gemini) create_gemini_sandbox "$PROJECT_DIR" "architect" "$PROJECT_DIR" ;;
    codex)  create_codex_sandbox "$PROJECT_DIR" "architect" "$PROJECT_DIR" ;;
esac

# --- Create worktrees and CLAUDE.md for each team member ---
mkdir -p "$WORKTREES_DIR"

# Prune stale worktree references before creating new ones
echo ""
echo "Pruning stale worktree references..."
git -C "$PROJECT_DIR" worktree prune

# Ensure .worktrees is in .gitignore
if [[ ! -f "$PROJECT_DIR/.gitignore" ]] || ! grep -qxF '.worktrees/' "$PROJECT_DIR/.gitignore"; then
    echo '.worktrees/' >> "$PROJECT_DIR/.gitignore"
    git -C "$PROJECT_DIR" add .gitignore
    git -C "$PROJECT_DIR" commit -m "Add .worktrees/ to .gitignore" 2>/dev/null || true
    echo "  Added .worktrees/ to .gitignore"
fi

for i in "${!TEAM_MEMBERS[@]}"; do
    MEMBER_SPEC="${TEAM_MEMBERS[$i]}"

    # Parse name:role:markdown:agent:model format
    MEMBER_NAME="${MEMBER_SPEC%%:*}"
    TEMP="${MEMBER_SPEC#*:}"
    MEMBER_ROLE="${TEMP%%:*}"
    TEMP="${TEMP#*:}"
    TEMP="${TEMP#*:}"
    MEMBER_AGENT="${TEMP%%:*}"
    MEMBER_MODEL="${TEMP#*:}"

    WORKTREE_PATH="$WORKTREES_DIR/$MEMBER_NAME"
    BRANCH_NAME="dev/$MEMBER_NAME"

    echo ""
    echo "Setting up $MEMBER_NAME (role: $MEMBER_ROLE, agent: $MEMBER_AGENT)"
    echo "  Worktree: $WORKTREE_PATH"
    echo "  Branch: $BRANCH_NAME"
    echo "  Persona: ${PERSONA_FILENAMES[$i]}"

    # Check if worktree is properly registered with git (not just directory presence)
    WORKTREE_REGISTERED=$(git -C "$PROJECT_DIR" worktree list --porcelain | grep "^worktree $WORKTREE_PATH$" || true)

    if [[ -n "$WORKTREE_REGISTERED" ]] && [[ -d "$WORKTREE_PATH" ]]; then
        echo "  Worktree already exists and is registered, skipping creation"
    else
        # Clean up orphaned directory if present without git registration
        if [[ -d "$WORKTREE_PATH" ]] && [[ -z "$WORKTREE_REGISTERED" ]]; then
            echo "  Warning: Directory exists without git worktree registration — removing orphaned directory..."
            rm -rf "$WORKTREE_PATH"
        fi

        # Create the branch if it doesn't exist
        if ! git -C "$PROJECT_DIR" show-ref --verify --quiet "refs/heads/$BRANCH_NAME"; then
            echo "  Creating branch $BRANCH_NAME..."
            git -C "$PROJECT_DIR" branch "$BRANCH_NAME" "$BASE_BRANCH"
        else
            # Branch exists — check if it's already checked out in another worktree
            BRANCH_CHECKED_OUT=$(git -C "$PROJECT_DIR" worktree list --porcelain | grep "^branch refs/heads/$BRANCH_NAME$" || true)
            if [[ -n "$BRANCH_CHECKED_OUT" ]]; then
                echo "  Warning: Branch $BRANCH_NAME is already checked out in another worktree — skipping worktree creation for $MEMBER_NAME"
                continue
            fi
            echo "  Branch $BRANCH_NAME already exists"
        fi

        # Create the worktree
        echo "  Creating worktree..."
        git -C "$PROJECT_DIR" worktree add "$WORKTREE_PATH" "$BRANCH_NAME"
    fi

    # Ensure .swarm/ files are present (copy from main project in case branch is behind)
    echo "  Ensuring .swarm/ files are present..."
    mkdir -p "$WORKTREE_PATH/.swarm/Personas"
    if [[ ${#CURRENT_GUIDANCE_FILES[@]} -gt 0 ]]; then
        mkdir -p "$WORKTREE_PATH/.swarm/Guidance"
    fi
    cp -r "$PROJECT_DIR/.swarm/Personas/"* "$WORKTREE_PATH/.swarm/Personas/"
    if [[ -d "$PROJECT_DIR/.swarm/Guidance" ]]; then
        cp -r "$PROJECT_DIR/.swarm/Guidance/"* "$WORKTREE_PATH/.swarm/Guidance/" 2>/dev/null || true
    fi

    # Write session instructions to CLAUDE.md (persona/guidance files are in git via .swarm/)
    CURRENT_PERSONA=".swarm/Personas/${PERSONA_FILENAMES[$i]}"
    write_session_instructions "$WORKTREE_PATH"

    # Create sandbox configuration based on agent type
    case "$MEMBER_AGENT" in
        claude) create_claude_sandbox "$WORKTREE_PATH" "$MEMBER_ROLE" "$WORKTREE_PATH" ;;
        gemini) create_gemini_sandbox "$WORKTREE_PATH" "$MEMBER_ROLE" "$WORKTREE_PATH" ;;
        codex)  create_codex_sandbox "$WORKTREE_PATH" "$MEMBER_ROLE" "$WORKTREE_PATH" ;;
    esac
done

# Kill existing tmux session if it exists
if tmux has-session -t dev 2>/dev/null; then
    echo ""
    echo "Killing existing 'dev' tmux session..."
    tmux kill-session -t dev
fi

# Create tmux session
echo ""
echo "Creating tmux session and launching AI agents..."

# Get architect CLI command
ARCHITECT_CLI=$(get_cli_command "$ARCHITECT_AGENT" "architect" "$ARCHITECT_MODEL")

# Start with the Architect window and launch CLI
tmux new-session -d -s dev -n Architect -c "$PROJECT_DIR"
# Set the iTerm2 window badge to the member name
tmux send-keys -t dev:Architect 'printf "\e]1337;SetBadgeFormat=%s\a" "$(echo -n "Architect" | base64)"' Enter
tmux send-keys -t dev:Architect "$ARCHITECT_CLI" Enter
echo "  Created window: Architect -> $PROJECT_DIR"
echo "    Launched: $ARCHITECT_CLI"

# Create a window for each team member and launch their CLI
for i in "${!TEAM_MEMBERS[@]}"; do
    MEMBER_SPEC="${TEAM_MEMBERS[$i]}"

    # Parse name:role:markdown:agent:model format
    MEMBER_NAME="${MEMBER_SPEC%%:*}"
    TEMP="${MEMBER_SPEC#*:}"
    MEMBER_ROLE="${TEMP%%:*}"
    TEMP="${TEMP#*:}"
    TEMP="${TEMP#*:}"
    MEMBER_AGENT="${TEMP%%:*}"
    MEMBER_MODEL="${TEMP#*:}"
    WORKTREE_PATH="$WORKTREES_DIR/$MEMBER_NAME"

    MEMBER_CLI=$(get_cli_command "$MEMBER_AGENT" "$MEMBER_ROLE" "$MEMBER_MODEL")

    tmux new-window -t dev -n "$MEMBER_NAME" -c "$WORKTREE_PATH"
    # Set the iTerm2 window badge to the member name
    tmux send-keys -t "dev:$MEMBER_NAME" 'printf "\e]1337;SetBadgeFormat=%s\a" '$(echo -n "$MEMBER_NAME" | base64)'' Enter
    tmux send-keys -t "dev:$MEMBER_NAME" "$MEMBER_CLI" Enter
    echo "  Created window: $MEMBER_NAME -> $WORKTREE_PATH"
    echo "    Launched: $MEMBER_CLI"
done

echo ""
echo "Attaching to tmux session (iTerm2 integration mode)..."
echo ""

# Attach to the session with iTerm2 integration (-CC flag)
tmux -CC attach -t dev
