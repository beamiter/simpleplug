use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::Command;
use tokio::sync::RwLock;

// ─────────────────── Protocol ───────────────────

#[derive(Debug, Deserialize)]
#[serde(tag = "type")]
enum Request {
    /// 安装/克隆一组插件
    #[serde(rename = "install")]
    Install { id: u64, plugins: Vec<PluginSpec> },
    /// 更新一组插件 (git pull)
    #[serde(rename = "update")]
    Update { id: u64, plugins: Vec<PluginSpec> },
    /// 清理未注册的插件目录
    #[serde(rename = "clean")]
    Clean {
        id: u64,
        plugdir: String,
        keep: Vec<String>,
    },
    /// 查询已安装插件状态
    #[serde(rename = "status")]
    Status { id: u64, plugins: Vec<PluginSpec> },
    /// 对单个插件执行 post-install 命令
    #[serde(rename = "post_hook")]
    PostHook {
        id: u64,
        name: String,
        dir: String,
        cmd: String,
    },
}

#[derive(Debug, Clone, Deserialize, Serialize)]
struct PluginSpec {
    name: String,
    url: String,
    dir: String,
    #[serde(default)]
    branch: String,
    #[serde(default)]
    do_cmd: String,
    #[serde(default)]
    frozen: bool,
}

#[derive(Debug, Serialize)]
#[serde(tag = "type")]
enum Event {
    /// 单个插件操作完成
    #[serde(rename = "progress")]
    Progress {
        id: u64,
        name: String,
        status: String,
        message: String,
    },
    /// 整批操作完成
    #[serde(rename = "done")]
    Done { id: u64, summary: Summary },
    /// 错误
    #[serde(rename = "error")]
    Error { id: u64, message: String },
    /// 状态查询结果
    #[serde(rename = "status_result")]
    StatusResult {
        id: u64,
        items: Vec<PluginStatus>,
    },
    /// post-hook 结果
    #[serde(rename = "hook_done")]
    HookDone {
        id: u64,
        name: String,
        ok: bool,
        output: String,
    },
    /// 清理结果
    #[serde(rename = "clean_done")]
    CleanDone {
        id: u64,
        removed: Vec<String>,
    },
}

#[derive(Debug, Serialize, Default)]
struct Summary {
    installed: u32,
    updated: u32,
    already_ok: u32,
    errors: u32,
}

#[derive(Debug, Serialize)]
struct PluginStatus {
    name: String,
    installed: bool,
    branch: String,
    commit: String,
    dirty: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    size_kb: Option<u64>,
}

// ─────────────────── stdout writer ───────────────────

type EventTx = tokio::sync::mpsc::Sender<String>;

async fn stdout_writer(mut rx: tokio::sync::mpsc::Receiver<String>) {
    let mut out = tokio::io::stdout();
    while let Some(line) = rx.recv().await {
        if out.write_all(line.as_bytes()).await.is_err() {
            break;
        }
        if out.write_all(b"\n").await.is_err() {
            break;
        }
        let _ = out.flush().await;
    }
}

async fn send_event(tx: &EventTx, evt: &Event) {
    if let Ok(line) = serde_json::to_string(evt) {
        let _ = tx.send(line).await;
    }
}

// ─────────────────── Main ───────────────────

#[tokio::main(flavor = "multi_thread")]
async fn main() -> std::io::Result<()> {
    let stdin = BufReader::new(tokio::io::stdin());
    let mut lines = stdin.lines();

    let (out_tx, out_rx) = tokio::sync::mpsc::channel::<String>(4096);
    tokio::spawn(stdout_writer(out_rx));

    // 简单的全局锁：防止并发写同一个插件目录
    let locks: Arc<RwLock<HashMap<String, Arc<tokio::sync::Mutex<()>>>>> =
        Arc::new(RwLock::new(HashMap::new()));

    while let Some(line) = lines.next_line().await? {
        if line.trim().is_empty() {
            continue;
        }
        let req = match serde_json::from_str::<Request>(&line) {
            Ok(r) => r,
            Err(e) => {
                send_event(
                    &out_tx,
                    &Event::Error {
                        id: 0,
                        message: format!("invalid request: {e}"),
                    },
                )
                .await;
                continue;
            }
        };

        let tx = out_tx.clone();
        let locks = locks.clone();

        tokio::spawn(async move {
            match req {
                Request::Install { id, plugins } => {
                    handle_install(id, plugins, &tx, &locks).await;
                }
                Request::Update { id, plugins } => {
                    handle_update(id, plugins, &tx, &locks).await;
                }
                Request::Clean {
                    id,
                    plugdir,
                    keep,
                } => {
                    handle_clean(id, &plugdir, &keep, &tx).await;
                }
                Request::Status { id, plugins } => {
                    handle_status(id, plugins, &tx).await;
                }
                Request::PostHook {
                    id,
                    name,
                    dir,
                    cmd,
                } => {
                    handle_post_hook(id, &name, &dir, &cmd, &tx).await;
                }
            }
        });
    }
    Ok(())
}

// ─────────────────── git helpers ───────────────────

async fn run_git(dir: &str, args: &[&str]) -> Result<String, String> {
    let output = Command::new("git")
        .args(args)
        .current_dir(dir)
        .output()
        .await
        .map_err(|e| format!("exec git: {e}"))?;

    if output.status.success() {
        Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        Err(stderr)
    }
}

async fn git_clone(url: &str, dir: &str, branch: &str) -> Result<String, String> {
    let mut args = vec!["clone", "--depth", "1"];
    if !branch.is_empty() {
        args.extend_from_slice(&["--branch", branch]);
    }
    args.push(url);
    args.push(dir);

    let output = Command::new("git")
        .args(&args)
        .output()
        .await
        .map_err(|e| format!("exec git clone: {e}"))?;

    if output.status.success() {
        Ok("cloned".to_string())
    } else {
        Err(String::from_utf8_lossy(&output.stderr).trim().to_string())
    }
}

async fn git_pull(dir: &str) -> Result<String, String> {
    // Try fast-forward first; if branches have diverged, force-sync to remote
    let result = run_git(dir, &["pull", "--ff-only", "--depth", "1"]).await;
    if result.is_ok() {
        return result;
    }
    // Diverged: fetch and reset to remote tracking branch
    let branch = git_current_branch(dir).await;
    let remote_ref = if branch.is_empty() {
        "origin/HEAD".to_string()
    } else {
        format!("origin/{branch}")
    };
    run_git(dir, &["fetch", "origin", "--depth", "1"]).await?;
    run_git(dir, &["reset", "--hard", &remote_ref]).await
}

async fn git_current_branch(dir: &str) -> String {
    run_git(dir, &["rev-parse", "--abbrev-ref", "HEAD"])
        .await
        .unwrap_or_default()
}

async fn git_current_commit(dir: &str) -> String {
    run_git(dir, &["rev-parse", "--short", "HEAD"])
        .await
        .unwrap_or_default()
}

async fn git_is_dirty(dir: &str) -> bool {
    run_git(dir, &["status", "--porcelain"])
        .await
        .map(|s| !s.is_empty())
        .unwrap_or(false)
}

async fn git_checkout_branch(dir: &str, branch: &str) -> Result<(), String> {
    if branch.is_empty() {
        return Ok(());
    }
    let current = git_current_branch(dir).await;
    if current == branch {
        return Ok(());
    }
    // fetch the branch first
    let _ = run_git(dir, &["fetch", "origin", branch, "--depth", "1"]).await;
    run_git(dir, &["checkout", branch]).await?;
    Ok(())
}

// ─────────────────── per-plugin lock ───────────────────

type DirLocks = Arc<RwLock<HashMap<String, Arc<tokio::sync::Mutex<()>>>>>;

async fn get_lock(locks: &DirLocks, dir: &str) -> Arc<tokio::sync::Mutex<()>> {
    {
        let map = locks.read().await;
        if let Some(l) = map.get(dir) {
            return l.clone();
        }
    }
    let mut map = locks.write().await;
    map.entry(dir.to_string())
        .or_insert_with(|| Arc::new(tokio::sync::Mutex::new(())))
        .clone()
}

// ─────────────────── install ───────────────────

async fn handle_install(id: u64, plugins: Vec<PluginSpec>, tx: &EventTx, locks: &DirLocks) {
    let mut summary = Summary::default();
    let mut handles = Vec::new();

    for p in plugins {
        let tx = tx.clone();
        let locks = locks.clone();
        handles.push(tokio::spawn(async move {
            let lock = get_lock(&locks, &p.dir).await;
            let _guard = lock.lock().await;

            let dir_path = PathBuf::from(&p.dir);
            if dir_path.join(".git").exists() {
                // 已安装 → 检查分支
                if !p.branch.is_empty() {
                    if let Err(e) = git_checkout_branch(&p.dir, &p.branch).await {
                        send_event(
                            &tx,
                            &Event::Progress {
                                id,
                                name: p.name.clone(),
                                status: "error".into(),
                                message: format!("checkout branch failed: {e}"),
                            },
                        )
                        .await;
                        return "error";
                    }
                }
                send_event(
                    &tx,
                    &Event::Progress {
                        id,
                        name: p.name.clone(),
                        status: "already".into(),
                        message: "already installed".into(),
                    },
                )
                .await;
                return "already";
            }

            // 克隆
            match git_clone(&p.url, &p.dir, &p.branch).await {
                Ok(_) => {
                    send_event(
                        &tx,
                        &Event::Progress {
                            id,
                            name: p.name.clone(),
                            status: "installed".into(),
                            message: "cloned".into(),
                        },
                    )
                    .await;

                    // 执行 post-install hook
                    if !p.do_cmd.is_empty() {
                        let hook_result = run_shell_cmd(&p.dir, &p.do_cmd).await;
                        let hook_msg = match &hook_result {
                            Ok(out) => format!("hook ok: {out}"),
                            Err(e) => format!("hook failed: {e}"),
                        };
                        send_event(
                            &tx,
                            &Event::Progress {
                                id,
                                name: p.name.clone(),
                                status: "hook".into(),
                                message: hook_msg,
                            },
                        )
                        .await;
                    }

                    "installed"
                }
                Err(e) => {
                    send_event(
                        &tx,
                        &Event::Progress {
                            id,
                            name: p.name.clone(),
                            status: "error".into(),
                            message: e,
                        },
                    )
                    .await;
                    "error"
                }
            }
        }));
    }

    for h in handles {
        if let Ok(result) = h.await {
            match result {
                "installed" => summary.installed += 1,
                "already" => summary.already_ok += 1,
                "error" => summary.errors += 1,
                _ => {}
            }
        }
    }

    send_event(tx, &Event::Done { id, summary }).await;
}

// ─────────────────── update ───────────────────

async fn handle_update(id: u64, plugins: Vec<PluginSpec>, tx: &EventTx, locks: &DirLocks) {
    let mut summary = Summary::default();
    let mut handles = Vec::new();

    for p in plugins {
        let tx = tx.clone();
        let locks = locks.clone();
        handles.push(tokio::spawn(async move {
            let lock = get_lock(&locks, &p.dir).await;
            let _guard = lock.lock().await;

            let dir_path = PathBuf::from(&p.dir);
            if !dir_path.join(".git").exists() {
                send_event(
                    &tx,
                    &Event::Progress {
                        id,
                        name: p.name.clone(),
                        status: "error".into(),
                        message: "not installed (no .git)".into(),
                    },
                )
                .await;
                return "error";
            }

            if p.frozen {
                send_event(
                    &tx,
                    &Event::Progress {
                        id,
                        name: p.name.clone(),
                        status: "skipped".into(),
                        message: "frozen".into(),
                    },
                )
                .await;
                return "already";
            }

            // 切换分支
            if !p.branch.is_empty() {
                if let Err(e) = git_checkout_branch(&p.dir, &p.branch).await {
                    send_event(
                        &tx,
                        &Event::Progress {
                            id,
                            name: p.name.clone(),
                            status: "error".into(),
                            message: format!("checkout: {e}"),
                        },
                    )
                    .await;
                    return "error";
                }
            }

            let old_commit = git_current_commit(&p.dir).await;

            match git_pull(&p.dir).await {
                Ok(_out) => {
                    let new_commit = git_current_commit(&p.dir).await;
                    let changed = old_commit != new_commit;
                    let status = if changed { "updated" } else { "already" };
                    let msg = if changed {
                        // 获取 diff 统计
                        let diff_stat = run_git(
                            &p.dir,
                            &["diff", "--shortstat", &old_commit, &new_commit],
                        )
                        .await
                        .unwrap_or_default();
                        if diff_stat.is_empty() {
                            format!("{old_commit} → {new_commit}")
                        } else {
                            format!("{old_commit} → {new_commit} | {diff_stat}")
                        }
                    } else {
                        "already up-to-date".into()
                    };

                    send_event(
                        &tx,
                        &Event::Progress {
                            id,
                            name: p.name.clone(),
                            status: status.into(),
                            message: msg,
                        },
                    )
                    .await;

                    // 如果有更新且有 post-hook，则执行
                    if changed && !p.do_cmd.is_empty() {
                        let hook_result = run_shell_cmd(&p.dir, &p.do_cmd).await;
                        let hook_msg = match &hook_result {
                            Ok(o) => format!("hook ok: {o}"),
                            Err(e) => format!("hook failed: {e}"),
                        };
                        send_event(
                            &tx,
                            &Event::Progress {
                                id,
                                name: p.name.clone(),
                                status: "hook".into(),
                                message: hook_msg,
                            },
                        )
                        .await;
                    }

                    if changed {
                        "updated"
                    } else {
                        "already"
                    }
                }
                Err(e) => {
                    send_event(
                        &tx,
                        &Event::Progress {
                            id,
                            name: p.name.clone(),
                            status: "error".into(),
                            message: e,
                        },
                    )
                    .await;
                    "error"
                }
            }
        }));
    }

    for h in handles {
        if let Ok(result) = h.await {
            match result {
                "updated" => summary.updated += 1,
                "already" => summary.already_ok += 1,
                "error" => summary.errors += 1,
                _ => {}
            }
        }
    }

    send_event(tx, &Event::Done { id, summary }).await;
}

// ─────────────────── clean ───────────────────

async fn handle_clean(id: u64, plugdir: &str, keep: &[String], tx: &EventTx) {
    let mut removed = Vec::new();

    let mut dir = match tokio::fs::read_dir(plugdir).await {
        Ok(d) => d,
        Err(e) => {
            send_event(
                tx,
                &Event::Error {
                    id,
                    message: format!("read plugdir: {e}"),
                },
            )
            .await;
            return;
        }
    };

    while let Ok(Some(entry)) = dir.next_entry().await {
        let name = entry.file_name().to_string_lossy().to_string();
        if keep.contains(&name) {
            continue;
        }
        let path = entry.path();
        if path.is_dir() {
            if let Err(e) = tokio::fs::remove_dir_all(&path).await {
                send_event(
                    tx,
                    &Event::Progress {
                        id,
                        name: name.clone(),
                        status: "error".into(),
                        message: format!("remove failed: {e}"),
                    },
                )
                .await;
            } else {
                removed.push(name);
            }
        }
    }

    send_event(tx, &Event::CleanDone { id, removed }).await;
}

// ─────────────────── status ───────────────────

async fn dir_size_kb(path: &std::path::Path) -> Option<u64> {
    let output = Command::new("du")
        .args(["-sk"])
        .arg(path)
        .output()
        .await
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let s = String::from_utf8_lossy(&output.stdout);
    s.split_whitespace().next()?.parse::<u64>().ok()
}

async fn handle_status(id: u64, plugins: Vec<PluginSpec>, tx: &EventTx) {
    let mut items = Vec::new();
    let mut handles = Vec::new();

    for p in plugins {
        handles.push(tokio::spawn(async move {
            let dir_path = PathBuf::from(&p.dir);
            let installed = dir_path.join(".git").exists();
            if !installed {
                return PluginStatus {
                    name: p.name,
                    installed: false,
                    branch: String::new(),
                    commit: String::new(),
                    dirty: false,
                    size_kb: None,
                };
            }
            let branch = git_current_branch(&p.dir).await;
            let commit = git_current_commit(&p.dir).await;
            let dirty = git_is_dirty(&p.dir).await;
            let size_kb = dir_size_kb(&dir_path).await;
            PluginStatus {
                name: p.name,
                installed,
                branch,
                commit,
                dirty,
                size_kb,
            }
        }));
    }

    for h in handles {
        if let Ok(s) = h.await {
            items.push(s);
        }
    }

    send_event(tx, &Event::StatusResult { id, items }).await;
}

// ─────────────────── post-hook ───────────────────

async fn handle_post_hook(id: u64, name: &str, dir: &str, cmd: &str, tx: &EventTx) {
    let result = run_shell_cmd(dir, cmd).await;
    let (ok, output) = match result {
        Ok(out) => (true, out),
        Err(e) => (false, e),
    };
    send_event(
        tx,
        &Event::HookDone {
            id,
            name: name.to_string(),
            ok,
            output,
        },
    )
    .await;
}

// ─────────────────── shell helper ───────────────────

async fn run_shell_cmd(dir: &str, cmd: &str) -> Result<String, String> {
    let output = Command::new("sh")
        .args(["-c", cmd])
        .current_dir(dir)
        .output()
        .await
        .map_err(|e| format!("exec: {e}"))?;

    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();

    if output.status.success() {
        Ok(if stdout.is_empty() { stderr } else { stdout })
    } else {
        Err(if stderr.is_empty() { stdout } else { stderr })
    }
}
