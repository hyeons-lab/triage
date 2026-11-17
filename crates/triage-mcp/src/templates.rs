use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use serde::Serialize;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RoleTemplate {
    pub name: String,
    pub path: PathBuf,
    pub command: Option<String>,
    pub args: Vec<String>,
    pub cwd: Option<String>,
    pub outlive_parent: Option<bool>,
    pub task_flag: Option<String>,
    pub prompt_body: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct RoleTemplateSummary {
    pub name: String,
    pub path: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
    pub args: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub outlive_parent: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub task_flag: Option<String>,
    pub has_prompt_body: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub prompt_preview: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedTemplateLaunch {
    pub command: String,
    pub args: Vec<String>,
    pub cwd: String,
    pub outlive_parent: bool,
}

pub fn default_templates_dir() -> Option<PathBuf> {
    if let Ok(override_dir) = std::env::var("TRIAGE_TEMPLATES_DIR") {
        let trimmed = override_dir.trim();
        if !trimmed.is_empty() {
            return Some(PathBuf::from(trimmed));
        }
    }
    if let Ok(xdg) = std::env::var("XDG_CONFIG_HOME") {
        let trimmed = xdg.trim();
        if !trimmed.is_empty() {
            return Some(PathBuf::from(trimmed).join("triage").join("templates"));
        }
    }
    let home = std::env::var("HOME")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .or_else(|| {
            std::env::var("USERPROFILE")
                .ok()
                .filter(|value| !value.trim().is_empty())
        })?;
    Some(
        PathBuf::from(home)
            .join(".config")
            .join("triage")
            .join("templates"),
    )
}

pub fn validate_template_name(name: &str) -> Result<&str> {
    let trimmed = name.trim();
    if trimmed.is_empty()
        || trimmed.starts_with('.')
        || trimmed.contains('/')
        || trimmed.contains('\\')
        || trimmed.contains("..")
        || trimmed.contains('\0')
    {
        bail!("invalid template name {name:?}");
    }
    Ok(trimmed)
}

pub fn load_template(dir: &Path, name: &str) -> Result<RoleTemplate> {
    let name = validate_template_name(name)?;
    let file_name = if name.ends_with(".md") {
        name.to_string()
    } else {
        format!("{name}.md")
    };
    let stem = file_name.strip_suffix(".md").unwrap_or(name).to_string();
    let path = dir.join(&file_name);
    let content = std::fs::read_to_string(&path)
        .with_context(|| format!("reading role template {}", path.display()))?;
    parse_role_template(&stem, path, &content)
}

pub fn list_templates(dir: &Path) -> Result<Vec<RoleTemplateSummary>> {
    if !dir.exists() {
        return Ok(Vec::new());
    }
    let mut templates = Vec::new();
    for entry in std::fs::read_dir(dir)
        .with_context(|| format!("reading templates directory {}", dir.display()))?
    {
        let entry = entry.context("reading templates directory entry")?;
        let path = entry.path();
        if !path.is_file() || path.extension().and_then(|s| s.to_str()) != Some("md") {
            continue;
        }
        let Some(stem) = path.file_stem().and_then(|s| s.to_str()).map(str::to_owned) else {
            continue;
        };
        if validate_template_name(&stem).is_err() {
            continue;
        }
        let content = std::fs::read_to_string(&path)
            .with_context(|| format!("reading role template {}", path.display()))?;
        let template = parse_role_template(&stem, path, &content)?;
        templates.push(template.summary());
    }
    templates.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(templates)
}

impl RoleTemplate {
    pub fn summary(&self) -> RoleTemplateSummary {
        let preview = if self.prompt_body.is_empty() {
            None
        } else {
            let line = self
                .prompt_body
                .lines()
                .map(str::trim)
                .find(|line| !line.is_empty())
                .unwrap_or("")
                .chars()
                .take(120)
                .collect::<String>();
            (!line.is_empty()).then_some(line)
        };
        RoleTemplateSummary {
            name: self.name.clone(),
            path: self.path.display().to_string(),
            command: self.command.clone(),
            args: self.args.clone(),
            cwd: self.cwd.clone(),
            outlive_parent: self.outlive_parent,
            task_flag: self.task_flag.clone(),
            has_prompt_body: !self.prompt_body.is_empty(),
            prompt_preview: preview,
        }
    }
}

pub fn parse_role_template(name: &str, path: PathBuf, raw: &str) -> Result<RoleTemplate> {
    let normalized = raw.replace("\r\n", "\n");
    let (frontmatter, body) = split_frontmatter(&normalized);
    let mut command = None;
    let mut args = Vec::new();
    let mut cwd = None;
    let mut outlive_parent = None;
    let mut task_flag = None;

    if let Some(fm) = frontmatter {
        let lines: Vec<&str> = fm.lines().collect();
        let mut idx = 0;
        while idx < lines.len() {
            let line = lines[idx].trim();
            idx += 1;
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let Some((raw_key, raw_val)) = line.split_once(':') else {
                bail!("invalid frontmatter line in {}: {line}", path.display());
            };
            let key = raw_key.trim();
            let val = raw_val.trim();
            match key {
                "command" => command = non_empty_unquoted(val),
                "cwd" => cwd = non_empty_unquoted(val),
                "task_flag" => task_flag = non_empty_unquoted(val),
                "outlive_parent" => {
                    let parsed = match val {
                        "true" => true,
                        "false" => false,
                        other => bail!(
                            "invalid boolean for outlive_parent in {}: {other}",
                            path.display()
                        ),
                    };
                    outlive_parent = Some(parsed);
                }
                "args" => {
                    if val.is_empty() {
                        while idx < lines.len() {
                            let next = lines[idx].trim_start();
                            if let Some(item) = next.strip_prefix("- ") {
                                args.push(unquote(item.trim()));
                                idx += 1;
                            } else if next.is_empty() {
                                idx += 1;
                            } else {
                                break;
                            }
                        }
                    } else if val.starts_with('[') {
                        args = serde_json::from_str::<Vec<String>>(val)
                            .with_context(|| format!("parsing args array in {}", path.display()))?;
                    } else {
                        args.push(unquote(val));
                    }
                }
                _ => {
                    // Ignore unknown metadata keys (such as `name` or `description`) cleanly.
                }
            }
        }
    }

    Ok(RoleTemplate {
        name: name.to_string(),
        path,
        command,
        args,
        cwd,
        outlive_parent,
        task_flag,
        prompt_body: body.trim().to_string(),
    })
}

pub fn resolve_template_launch(
    template: Option<&RoleTemplate>,
    caller_command: Option<String>,
    caller_args: Vec<String>,
    caller_cwd: Option<String>,
    caller_outlive_parent: Option<bool>,
    task: Option<String>,
) -> Result<ResolvedTemplateLaunch> {
    let command = caller_command
        .filter(|value| !value.trim().is_empty())
        .or_else(|| template.and_then(|t| t.command.clone()))
        .ok_or_else(|| anyhow::anyhow!("start_session requires command (or template.command)"))?;

    let cwd = caller_cwd
        .filter(|value| !value.trim().is_empty())
        .or_else(|| template.and_then(|t| t.cwd.clone()))
        .ok_or_else(|| anyhow::anyhow!("start_session requires cwd (or template.cwd)"))?;

    let outlive_parent = caller_outlive_parent
        .or_else(|| template.and_then(|t| t.outlive_parent))
        .unwrap_or(false);

    let rendered_prompt = render_prompt(template.map(|t| t.prompt_body.as_str()), task.as_deref());
    let mut final_args = Vec::new();
    let mut substituted_prompt = false;

    if let Some(tmpl) = template {
        for raw_arg in &tmpl.args {
            let prompt_ref = rendered_prompt.as_deref().unwrap_or("");
            let task_ref = task.as_deref().unwrap_or("");
            if raw_arg.contains("{{prompt}}")
                || raw_arg.contains("{prompt}")
                || raw_arg.contains("{{task}}")
                || raw_arg.contains("{task}")
            {
                substituted_prompt = true;
                let replaced = raw_arg
                    .replace("{{prompt}}", prompt_ref)
                    .replace("{prompt}", prompt_ref)
                    .replace("{{task}}", task_ref)
                    .replace("{task}", task_ref);
                if !replaced.is_empty() {
                    final_args.push(replaced);
                }
            } else {
                final_args.push(raw_arg.clone());
            }
        }
    }

    final_args.extend(caller_args);

    if !substituted_prompt && let Some(prompt) = rendered_prompt {
        if let Some(flag) = template.and_then(|t| t.task_flag.as_ref()) {
            final_args.push(flag.clone());
        }
        final_args.push(prompt);
    }

    Ok(ResolvedTemplateLaunch {
        command,
        args: final_args,
        cwd,
        outlive_parent,
    })
}

fn render_prompt(body: Option<&str>, task: Option<&str>) -> Option<String> {
    let body = body.map(str::trim).filter(|value| !value.is_empty());
    let task = task.map(str::trim).filter(|value| !value.is_empty());
    match (body, task) {
        (Some(body), Some(task)) => {
            if body.contains("{{task}}") || body.contains("{task}") {
                Some(body.replace("{{task}}", task).replace("{task}", task))
            } else {
                Some(format!("{body}\n\nTask: {task}"))
            }
        }
        (Some(body), None) => Some(
            body.replace("{{task}}", "")
                .replace("{task}", "")
                .trim()
                .to_string(),
        )
        .filter(|value| !value.is_empty()),
        (None, Some(task)) => Some(task.to_string()),
        (None, None) => None,
    }
}

fn split_frontmatter(input: &str) -> (Option<&str>, &str) {
    let Some(rest) = input.strip_prefix("---\n") else {
        return (None, input);
    };
    if let Some(end) = rest.find("\n---\n") {
        let fm = &rest[..end];
        let body = &rest[end + "\n---\n".len()..];
        (Some(fm), body)
    } else if let Some(fm) = rest.strip_suffix("\n---") {
        (Some(fm), "")
    } else {
        (None, input)
    }
}

fn non_empty_unquoted(value: &str) -> Option<String> {
    let parsed = unquote(value);
    (!parsed.trim().is_empty()).then_some(parsed)
}

fn unquote(value: &str) -> String {
    let trimmed = value.trim();
    if trimmed.len() >= 2
        && ((trimmed.starts_with('"') && trimmed.ends_with('"'))
            || (trimmed.starts_with('\'') && trimmed.ends_with('\'')))
    {
        trimmed[1..trimmed.len() - 1].to_string()
    } else {
        trimmed.to_string()
    }
}
