use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::process::Command;
use tokio::sync::{RwLock, Semaphore};

const DEFAULT_JOBS: usize = 8;
const MAX_JOBS: usize = 64;

/// The largest request this daemon will assemble.  An install/update request
/// carries one spec per plugin in the user's vimrc — a few hundred bytes each
/// — so this sits far above any real configuration while staying finite: a Vim
/// channel that dies mid-write leaves a partial line, and a client that loses
/// its newline must not grow the daemon until the machine runs out of memory.
const MAX_REQUEST_LINE_BYTES: usize = 8 * 1024 * 1024;

/// How much of a post-update hook's output is kept, per stream.  Hooks are
/// `make`, `npm ci`, `./install.sh`; a chatty build prints hundreds of
/// megabytes, and every byte of it would otherwise be buffered whole and then
/// serialised into a single `hook_done` JSON line for Vim to read.
const MAX_HOOK_OUTPUT_BYTES: usize = 64 * 1024;

/// Cleared before every `git` this daemon starts.  Vim inherits whatever the
/// shell that started it exported, so a stray `GIT_DIR` — from a git hook, or
/// from `git rebase --exec vim` — would otherwise redirect every plugin's git
/// at that repository instead of at the plugin directory.
const GIT_REPOSITORY_ENV_VARS: [&str; 8] = [
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_COMMON_DIR",
    "GIT_CEILING_DIRECTORIES",
    "GIT_DISCOVERY_ACROSS_FILESYSTEM",
];

fn default_jobs() -> usize {
    DEFAULT_JOBS
}

fn job_limit(jobs: usize) -> usize {
    jobs.clamp(1, MAX_JOBS)
}

// ─────────────────── Protocol ───────────────────

#[derive(Debug, Deserialize)]
#[serde(tag = "type")]
enum Request {
    /// 安装/克隆一组插件
    #[serde(rename = "install")]
    Install {
        id: u64,
        plugins: Vec<PluginSpec>,
        #[serde(default = "default_jobs")]
        jobs: usize,
    },
    /// 更新一组插件 (git pull)
    #[serde(rename = "update")]
    Update {
        id: u64,
        plugins: Vec<PluginSpec>,
        #[serde(default = "default_jobs")]
        jobs: usize,
    },
    /// 清理未注册的插件目录
    #[serde(rename = "clean")]
    Clean {
        id: u64,
        plugdir: String,
        keep: Vec<String>,
    },
    /// 查询已安装插件状态
    #[serde(rename = "status")]
    Status {
        id: u64,
        plugins: Vec<PluginSpec>,
        #[serde(default = "default_jobs")]
        jobs: usize,
    },
    /// 只读地问一句"有没有更新"：fetch 之后只数提交，不动工作区、不跑 hook
    #[serde(rename = "check")]
    Check {
        id: u64,
        plugins: Vec<PluginSpec>,
        #[serde(default = "default_jobs")]
        jobs: usize,
    },
    /// 对单个插件执行 post-install 命令
    #[serde(rename = "post_hook")]
    PostHook {
        id: u64,
        name: String,
        dir: String,
        cmd: String,
    },
    /// 能力握手：Vim 端每次启动 daemon 后发一次，按回复决定启用哪些特性，
    /// 旧 daemon 配新插件时降级而不是行为错乱。
    #[serde(rename = "ping")]
    Ping {
        #[serde(default)]
        id: u64,
    },
}

/// 线格式变更时递增。v1 是尚未协商的隐式格式。
const PROTOCOL_VERSION: u32 = 2;

fn capabilities() -> BTreeMap<&'static str, bool> {
    BTreeMap::from([
        ("install", true),
        ("update", true),
        ("clean", true),
        ("status", true),
        ("post_hook", true),
        ("tag_pin", true),
        ("commit_pin", true),
        ("submodules", true),
        ("update_detail", true),
        ("check", true),
    ])
}

#[derive(Debug, Clone, Deserialize, Serialize)]
struct PluginSpec {
    name: String,
    url: String,
    dir: String,
    #[serde(default)]
    branch: String,
    #[serde(default)]
    tag: String,
    #[serde(default)]
    commit: String,
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
    /// 一次 update 到底带进来了什么。
    ///
    /// 刻意独立于 `progress` 而不是往它身上加字段：`progress` 有三十来个构造
    /// 点，其中绝大多数（working/error/hook/frozen/dirty）永远没有 diff 可报，
    /// 给它们全部补上 `from: None, to: None, subjects: None` 只会让噪声淹没
    /// 真正带信息的那一个。旧的 Vim 端不认识这个事件类型，会照常忽略。
    ///
    /// `from`/`to` 是完整 OID：`:PlugDiff` 的回滚要把 `from` 当成 commit pin
    /// 发回来，而 Vim 端在把任何 revision 交给 git 之前只接受完整 OID。
    #[serde(rename = "update_detail")]
    UpdateDetail {
        id: u64,
        name: String,
        from: String,
        to: String,
        subjects: Vec<String>,
    },
    /// 整批操作完成
    #[serde(rename = "done")]
    Done { id: u64, summary: Summary },
    /// 错误
    #[serde(rename = "error")]
    Error { id: u64, message: String },
    /// 状态查询结果
    #[serde(rename = "status_result")]
    StatusResult { id: u64, items: Vec<PluginStatus> },
    /// 更新检查结果
    #[serde(rename = "check_result")]
    CheckResult { id: u64, items: Vec<CheckItem> },
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
    CleanDone { id: u64, removed: Vec<String> },
    /// 握手回复
    #[serde(rename = "pong")]
    Pong {
        id: u64,
        protocol_version: u32,
        version: &'static str,
        capabilities: BTreeMap<&'static str, bool>,
    },
}

#[derive(Debug, Serialize, Default)]
struct Summary {
    installed: u32,
    updated: u32,
    already_ok: u32,
    errors: u32,
}

/// `state` 说明这一行为什么长这样，Vim 端据此上色，不必去解析 message：
/// `behind`（有 N 个新提交）、`current`、`pinned`（tag/commit 锁定，不联网）、
/// `frozen`（update 本来就不会碰它，不联网）、`error`。
#[derive(Debug, Serialize)]
struct CheckItem {
    name: String,
    state: &'static str,
    behind: u32,
    dirty: bool,
    subjects: Vec<String>,
    #[serde(skip_serializing_if = "String::is_empty")]
    message: String,
}

#[derive(Debug, Serialize)]
struct PluginStatus {
    name: String,
    installed: bool,
    branch: String,
    commit: String,
    dirty: bool,
    #[serde(skip_serializing_if = "String::is_empty")]
    last_commit: String,
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

const USAGE: &str = "\
Usage: simpleplug-daemon [OPTION]

With no arguments the daemon serves newline-delimited JSON requests on stdin
and writes replies to stdout.  That is how the Vim plugin starts it; there is
nothing useful to do with it interactively.

Options:
  -V, --version    print the version and exit
  -h, --help       print this help and exit
      --self-test  check that the handshake reply serialises and that it
                   announces this build's protocol version, then exit
";

/// Cheap coherence check for the installer.
///
/// The request loop lives inside `main` and cannot be driven in-process
/// without restructuring it, so this stops short of a full round trip: it
/// builds the handshake reply the Vim side gates its features on and confirms
/// it serialises to the announced protocol version.  That catches a mismatched
/// or half-linked binary, which is what the installer is actually asking about.
fn self_test() -> Result<(), String> {
    let pong = Event::Pong {
        id: 0,
        protocol_version: PROTOCOL_VERSION,
        version: env!("CARGO_PKG_VERSION"),
        capabilities: capabilities(),
    };
    let encoded =
        serde_json::to_string(&pong).map_err(|error| format!("handshake reply: {error}"))?;
    let parsed: serde_json::Value =
        serde_json::from_str(&encoded).map_err(|error| format!("handshake reply: {error}"))?;

    match parsed.get("protocol_version").and_then(|v| v.as_u64()) {
        Some(version) if version == u64::from(PROTOCOL_VERSION) => Ok(()),
        Some(version) => Err(format!(
            "handshake announced protocol {version}, this build is {PROTOCOL_VERSION}"
        )),
        None => Err(format!("handshake carried no protocol version: {encoded}")),
    }
}

#[tokio::main(flavor = "multi_thread")]
async fn main() -> std::process::ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        None => match serve().await {
            Ok(()) => std::process::ExitCode::SUCCESS,
            Err(error) => {
                eprintln!("simpleplug-daemon: {error}");
                std::process::ExitCode::FAILURE
            }
        },
        Some("--version" | "-V") => {
            println!("simpleplug-daemon {}", env!("CARGO_PKG_VERSION"));
            std::process::ExitCode::SUCCESS
        }
        Some("--help" | "-h") => {
            println!("simpleplug-daemon {}\n\n{USAGE}", env!("CARGO_PKG_VERSION"));
            std::process::ExitCode::SUCCESS
        }
        Some("--self-test") => match self_test() {
            Ok(()) => {
                println!("ok");
                std::process::ExitCode::SUCCESS
            }
            Err(message) => {
                eprintln!("self-test failed: {message}");
                std::process::ExitCode::FAILURE
            }
        },
        Some(other) => {
            eprintln!("unknown argument: {other}\n\n{USAGE}");
            std::process::ExitCode::from(2)
        }
    }
}

fn finish_request_line(mut bytes: Vec<u8>, too_long: bool) -> Result<String, String> {
    if bytes.last() == Some(&b'\r') {
        bytes.pop();
    }
    if too_long || bytes.len() > MAX_REQUEST_LINE_BYTES {
        return Err(format!(
            "request line exceeds {MAX_REQUEST_LINE_BYTES} bytes"
        ));
    }
    String::from_utf8(bytes).map_err(|_| "request line is not valid UTF-8".to_string())
}

/// Read one bounded JSONL record, discarding the remainder of an oversized one
/// through its newline so that the next well-formed request is still served.
///
/// `AsyncBufReadExt::lines()`, which this replaced, can offer neither
/// guarantee: it grows a single String until the next newline arrives or the
/// allocator gives up, and once it has it cannot skip the malformed record.
async fn read_request_line<R>(
    reader: &mut BufReader<R>,
) -> std::io::Result<Option<Result<String, String>>>
where
    R: AsyncRead + Unpin,
{
    let mut bytes = Vec::new();
    let mut too_long = false;

    loop {
        let available = reader.fill_buf().await?;
        if available.is_empty() {
            return if bytes.is_empty() && !too_long {
                Ok(None)
            } else {
                Ok(Some(finish_request_line(bytes, too_long)))
            };
        }

        let newline = available.iter().position(|byte| *byte == b'\n');
        let content_len = newline.unwrap_or(available.len());
        let consumed = newline.map_or(available.len(), |position| position + 1);

        if !too_long {
            // Keep one framing byte until the record ends.  A terminal CR in
            // CRLF is not part of the JSONL payload's documented size limit.
            if bytes.len().saturating_add(content_len) > MAX_REQUEST_LINE_BYTES.saturating_add(1) {
                too_long = true;
                bytes.clear();
            } else {
                bytes.extend_from_slice(&available[..content_len]);
            }
        }
        reader.consume(consumed);

        if newline.is_some() {
            return Ok(Some(finish_request_line(bytes, too_long)));
        }
    }
}

async fn serve() -> std::io::Result<()> {
    let (out_tx, out_rx) = tokio::sync::mpsc::channel::<String>(4096);
    let writer = tokio::spawn(stdout_writer(out_rx));

    let result = process_requests(tokio::io::stdin(), out_tx.clone()).await;

    // stdin EOF：请求都已收尾（见 process_requests），让 writer 把事件刷完。
    drop(out_tx);
    let _ = writer.await;
    result
}

/// The request loop, over any reader so a test can drive it end to end.
async fn process_requests<R>(input: R, out_tx: EventTx) -> std::io::Result<()>
where
    R: AsyncRead + Unpin,
{
    let mut input = BufReader::new(input);

    // 简单的全局锁：防止并发写同一个插件目录
    let locks: Arc<RwLock<HashMap<String, Arc<tokio::sync::Mutex<()>>>>> =
        Arc::new(RwLock::new(HashMap::new()));

    let mut tasks = tokio::task::JoinSet::new();

    loop {
        let Some(line) = read_request_line(&mut input).await? else {
            break;
        };
        let line = match line {
            Ok(line) => line,
            Err(message) => {
                send_event(&out_tx, &Event::Error { id: 0, message }).await;
                continue;
            }
        };
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

        tasks.spawn(async move {
            match req {
                Request::Ping { id } => {
                    send_event(
                        &tx,
                        &Event::Pong {
                            id,
                            protocol_version: PROTOCOL_VERSION,
                            version: env!("CARGO_PKG_VERSION"),
                            capabilities: capabilities(),
                        },
                    )
                    .await;
                }
                Request::Install { id, plugins, jobs } => {
                    handle_install(id, plugins, jobs, &tx, &locks).await;
                }
                Request::Update { id, plugins, jobs } => {
                    handle_update(id, plugins, jobs, &tx, &locks).await;
                }
                Request::Clean { id, plugdir, keep } => {
                    handle_clean(id, &plugdir, &keep, &tx).await;
                }
                Request::Status { id, plugins, jobs } => {
                    handle_status(id, plugins, jobs, &tx).await;
                }
                Request::Check { id, plugins, jobs } => {
                    handle_check(id, plugins, jobs, &tx, &locks).await;
                }
                Request::PostHook { id, name, dir, cmd } => {
                    handle_post_hook(id, &name, &dir, &cmd, &tx).await;
                }
            }
        });
    }

    // stdin EOF：等所有进行中的请求收尾，调用者随后关闭事件通道。
    while tasks.join_next().await.is_some() {}
    Ok(())
}

// ─────────────────── git helpers ───────────────────

const DEFAULT_GIT_TIMEOUT_SECS: u64 = 300;
const DEFAULT_HOOK_TIMEOUT_SECS: u64 = 600;
/// `du` walks a plugin directory that may sit on a network mount or hold a
/// symlink loop, and it does so while holding one of `handle_status`'s job
/// permits.  A status listing that could not measure a directory is worth far
/// more than a status listing that never arrives, so this deadline is short.
const DEFAULT_SIZE_TIMEOUT_SECS: u64 = 30;

fn timeout_from_env(var: &str, default_secs: u64) -> std::time::Duration {
    let secs = std::env::var(var)
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .filter(|v| *v > 0)
        .unwrap_or(default_secs);
    std::time::Duration::from_secs(secs)
}

fn git_timeout() -> std::time::Duration {
    timeout_from_env("SIMPLEPLUG_GIT_TIMEOUT", DEFAULT_GIT_TIMEOUT_SECS)
}

fn hook_timeout() -> std::time::Duration {
    timeout_from_env("SIMPLEPLUG_HOOK_TIMEOUT", DEFAULT_HOOK_TIMEOUT_SECS)
}

fn size_timeout() -> std::time::Duration {
    timeout_from_env("SIMPLEPLUG_SIZE_TIMEOUT", DEFAULT_SIZE_TIMEOUT_SECS)
}

async fn run_with_timeout(
    mut cmd: Command,
    label: &str,
    timeout: std::time::Duration,
) -> Result<std::process::Output, String> {
    // A daemon must never sit on an interactive credential prompt.
    cmd.env("GIT_TERMINAL_PROMPT", "0");
    cmd.kill_on_drop(true);
    match tokio::time::timeout(timeout, cmd.output()).await {
        Ok(result) => result.map_err(|e| format!("exec {label}: {e}")),
        Err(_) => Err(format!("{label} timed out after {}s", timeout.as_secs())),
    }
}

/// What a `git` invocation actually established.
///
/// Most callers only care whether it worked, and `run_git` still gives them a
/// plain `Result`.  Anything that is about to *delete* a directory does not
/// have that luxury: collapsing "git ran and said no" into the same `Err` as
/// "git never ran at all" is how a git that is not on PATH came to look
/// exactly like an unusable checkout.
enum GitOutcome {
    Ok(String),
    /// git ran and exited non-zero.  The payload is git's own stderr, so it is
    /// a verdict about the repository.
    Failed(String),
    /// git produced no verdict: not on PATH, not executable, or killed by the
    /// timeout.  Says nothing whatsoever about the repository.
    Unavailable(String),
}

/// Every `git` this daemon starts.
///
/// The ambient repository environment is removed here rather than at each call
/// site, so no subcommand added later can forget it; simplegit and simpleline
/// clear the same eight variables for the same reason.
fn git_command(args: &[&str]) -> Command {
    let mut cmd = Command::new("git");
    cmd.args(args);
    for variable in GIT_REPOSITORY_ENV_VARS {
        cmd.env_remove(variable);
    }
    cmd
}

async fn try_git(dir: &str, args: &[&str]) -> GitOutcome {
    let mut cmd = git_command(args);
    cmd.current_dir(dir);
    match run_with_timeout(cmd, "git", git_timeout()).await {
        Err(e) => GitOutcome::Unavailable(e),
        Ok(output) if output.status.success() => {
            GitOutcome::Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
        }
        Ok(output) => {
            GitOutcome::Failed(String::from_utf8_lossy(&output.stderr).trim().to_string())
        }
    }
}

async fn run_git(dir: &str, args: &[&str]) -> Result<String, String> {
    match try_git(dir, args).await {
        GitOutcome::Ok(out) => Ok(out),
        GitOutcome::Failed(e) | GitOutcome::Unavailable(e) => Err(e),
    }
}

async fn git_clone(url: &str, dir: &str, refname: &str) -> Result<(), String> {
    let mut args = vec![
        "clone",
        "--depth",
        "1",
        "--recurse-submodules",
        "--shallow-submodules",
    ];
    // --branch accepts both branch names and tags.
    if !refname.is_empty() {
        args.extend_from_slice(&["--branch", refname]);
    }
    args.push(url);
    args.push(dir);

    let cmd = git_command(&args);
    let output = run_with_timeout(cmd, "git clone", git_timeout()).await?;

    if output.status.success() {
        Ok(())
    } else {
        Err(String::from_utf8_lossy(&output.stderr).trim().to_string())
    }
}

/// What a plugin directory actually is.
///
/// A `.git` entry is not proof of a usable checkout.  `git clone` creates the
/// target and its `.git` before the objects finish transferring, and the
/// partial-directory cleanup in `clone_plugin` only runs on its Err path —
/// which never executes when the process is killed instead of failing.
/// `:PlugStop` and VimLeavePre both send SIGTERM, so an install interrupted by
/// quitting Vim leaves exactly that.
///
/// The one thing this must never do is answer `Interrupted` when it does not
/// know, because `Interrupted` is what authorises `remove_dir_all`.
enum CheckoutState {
    /// Nothing here that git would call a repository.
    Missing,
    /// A checkout whose HEAD resolves to a commit.
    Valid,
    /// git resolved `.git`, HEAD names no commit, and the clone that produced
    /// it never finished.  Only a re-clone fixes this.
    Interrupted,
    /// The same unborn HEAD, but the clone *did* finish: the upstream simply
    /// has no commits yet.  Re-cloning would land right back here, forever.
    EmptyUpstream,
    /// git could not answer.  It is not on PATH, it timed out, or it refuses
    /// to treat the directory as a repository — dubious ownership on a tree
    /// owned by another uid, an unreadable `.git`, a `.git` file pointing at a
    /// gitdir that is gone.  None of that is evidence about the user's files,
    /// so none of it may delete them.
    Undetermined(String),
}

async fn git_checkout_state(dir: &str) -> CheckoutState {
    let gitdir = Path::new(dir).join(".git");
    if !gitdir.exists() {
        return CheckoutState::Missing;
    }
    let Some(gitdir) = gitdir.to_str() else {
        return CheckoutState::Undetermined(format!("{dir}/.git is not valid UTF-8"));
    };
    // `--resolve-git-dir` comes first because a `.git` that is not a valid
    // repository makes git's discovery walk *up*: without it, a plugged/ tree
    // inside a dotfiles repository would answer with that repository's HEAD
    // and a broken checkout would still look healthy.
    match try_git(dir, &["rev-parse", "--resolve-git-dir", gitdir]).await {
        GitOutcome::Ok(_) => {}
        GitOutcome::Failed(e) | GitOutcome::Unavailable(e) => {
            return CheckoutState::Undetermined(e);
        }
    }
    match try_git(dir, &["rev-parse", "--verify", "HEAD"]).await {
        GitOutcome::Ok(_) => CheckoutState::Valid,
        GitOutcome::Unavailable(e) => CheckoutState::Undetermined(e),
        GitOutcome::Failed(_) if clone_completed(dir).await => CheckoutState::EmptyUpstream,
        GitOutcome::Failed(_) => CheckoutState::Interrupted,
    }
}

/// Did the `git clone` that produced this directory run to completion?
///
/// `git clone` writes `remote.origin.url` before it fetches, but the
/// `branch.<name>.remote` pair only afterwards, once HEAD has been pointed at
/// the branch it fetched.  An unborn HEAD *with* that config is therefore a
/// finished clone of a repository that has no commits yet, not a transfer that
/// was killed halfway through.
async fn clone_completed(dir: &str) -> bool {
    let Ok(branch) = run_git(dir, &["symbolic-ref", "--quiet", "--short", "HEAD"]).await else {
        return false;
    };
    if branch.is_empty() {
        return false;
    }
    run_git(
        dir,
        &["config", "--get", &format!("branch.{branch}.remote")],
    )
    .await
    .is_ok()
}

/// Is there anything in this working tree that a re-clone would destroy?
///
/// Fails closed.  An answer git could not give is not permission to delete: on
/// an unborn HEAD `git status --porcelain` still lists every untracked file,
/// so a genuinely interrupted clone — which never got as far as checking
/// anything out — is the only thing that comes back empty.
async fn worktree_has_local_changes(dir: &str) -> Result<bool, String> {
    match try_git(dir, &["status", "--porcelain"]).await {
        GitOutcome::Ok(out) => Ok(!out.is_empty()),
        GitOutcome::Failed(e) | GitOutcome::Unavailable(e) => Err(e),
    }
}

/// A checkout of a repository that had no commits when it was cloned.  Fetch
/// once: if the upstream has since grown a branch, adopt it; otherwise there is
/// still nothing to update to, and saying so beats re-cloning it every run.
async fn adopt_first_upstream_commit(dir: &str) -> Result<Option<String>, String> {
    let Some(branch) = git_remote_head_branch(dir).await else {
        return Ok(None);
    };
    let tip = git_fetch_branch(dir, &branch).await?;
    run_git(dir, &["checkout", "-B", &branch, &tip]).await?;
    git_ensure_fetch_refspec(dir, &branch).await;
    let _ = run_git(
        dir,
        &[
            "branch",
            "--set-upstream-to",
            &format!("origin/{branch}"),
            &branch,
        ],
    )
    .await;
    Ok(Some(format!(
        "adopted origin/{branch} at {}",
        short_commit(&tip)
    )))
}

fn short_commit(commit: &str) -> &str {
    if commit.len() > 10 {
        &commit[..10]
    } else {
        commit
    }
}

/// Clone a plugin, retrying once on failure (transient network errors are
/// common), then apply an exact commit pin when one is requested.
/// Returns a human-readable success message.
async fn clone_plugin(
    p: &PluginSpec,
    dir_existed: bool,
    id: u64,
    tx: &EventTx,
) -> Result<String, String> {
    let refname = if !p.commit.is_empty() {
        // Pinned commits are checked out after a default-branch clone.
        ""
    } else if !p.tag.is_empty() {
        p.tag.as_str()
    } else {
        p.branch.as_str()
    };

    if let Err(first) = git_clone(&p.url, &p.dir, refname).await {
        if !dir_existed {
            let _ = tokio::fs::remove_dir_all(&p.dir).await;
        }
        send_event(
            tx,
            &Event::Progress {
                id,
                name: p.name.clone(),
                status: "working".into(),
                message: format!("clone failed, retrying: {first}"),
            },
        )
        .await;
        tokio::time::sleep(std::time::Duration::from_secs(1)).await;
        git_clone(&p.url, &p.dir, refname)
            .await
            .map_err(|e| format!("{e} (after retry)"))?;
    }

    if !p.commit.is_empty() {
        git_pin_commit(&p.dir, &p.commit)
            .await
            .map_err(|e| format!("pin commit: {e}"))?;
        git_sync_submodules(&p.dir).await?;
        return Ok(format!("cloned (pinned at {})", short_commit(&p.commit)));
    }
    if !p.tag.is_empty() {
        return Ok(format!("cloned (tag {})", p.tag));
    }
    Ok("cloned".to_string())
}

fn branch_refspec(branch: &str) -> String {
    format!("+refs/heads/{branch}:refs/remotes/origin/{branch}")
}

async fn git_fetch_branch(dir: &str, branch: &str) -> Result<String, String> {
    run_git(
        dir,
        &["fetch", "--depth", "1", "origin", &branch_refspec(branch)],
    )
    .await?;
    run_git(dir, &["rev-parse", "FETCH_HEAD"]).await
}

/// The branch origin's HEAD points at. Used to recover when the checkout has no
/// branch, or tracks one that no longer exists upstream.
async fn git_remote_head_branch(dir: &str) -> Option<String> {
    let out = run_git(dir, &["ls-remote", "--symref", "origin", "HEAD"])
        .await
        .ok()?;
    out.lines()
        .find_map(|line| line.strip_prefix("ref: "))
        .and_then(|rest| rest.split_whitespace().next())
        .and_then(|r| r.strip_prefix("refs/heads/"))
        .map(str::to_string)
}

async fn git_is_shallow(dir: &str) -> bool {
    run_git(dir, &["rev-parse", "--is-shallow-repository"])
        .await
        .map(|s| s == "true")
        .unwrap_or(false)
}

async fn git_is_ancestor(dir: &str, ancestor: &str, descendant: &str) -> bool {
    run_git(dir, &["merge-base", "--is-ancestor", ancestor, descendant])
        .await
        .is_ok()
}

/// A clone made with `--depth 1 --branch <b>` only fetches `<b>`; make sure the
/// refspec follows the branch we actually track, without narrowing a full clone.
async fn git_ensure_fetch_refspec(dir: &str, branch: &str) {
    let existing = run_git(dir, &["config", "--get-all", "remote.origin.fetch"])
        .await
        .unwrap_or_default();
    let covered = existing
        .lines()
        .any(|l| l.contains("refs/heads/*") || l.contains(&format!("refs/heads/{branch}:")));
    if !covered {
        let _ = run_git(
            dir,
            &["config", "remote.origin.fetch", &branch_refspec(branch)],
        )
        .await;
    }
}

/// Fast-forward the checkout onto origin's tip.
///
/// Never rewrites a user's local history: a genuine divergence is reported and
/// left for the user to resolve. `git pull --ff-only --depth 1` cannot do this
/// job, because it fails on three states that are not divergences at all — a
/// detached HEAD has no branch to pull into, a branch renamed upstream (main →
/// master) leaves the local branch tracking a ref that is gone, and a depth-1
/// fetch grafts away the commits linking HEAD to the new tip, which makes an
/// ordinary fast-forward look like diverged history.
async fn git_pull(dir: &str) -> Result<String, String> {
    let current = git_current_branch(dir).await;
    let detached = current.is_empty() || current == "HEAD";

    // Try the checked-out branch first, and fall back to origin's default branch
    // when there is none or it no longer exists upstream.
    let mut target = String::new();
    let mut tip = String::new();
    let mut first_err = None;
    if !detached {
        match git_fetch_branch(dir, &current).await {
            Ok(head) => {
                target = current.clone();
                tip = head;
            }
            Err(e) => first_err = Some(e),
        }
    }
    if target.is_empty() {
        let fallback = git_remote_head_branch(dir).await.ok_or_else(|| {
            first_err
                .clone()
                .unwrap_or_else(|| "cannot determine origin's default branch".to_string())
        })?;
        tip = git_fetch_branch(dir, &fallback).await.map_err(|e| {
            first_err
                .clone()
                .map_or(e.clone(), |first| format!("{first}; {e}"))
        })?;
        target = fallback;
    }

    // Restore the ancestry the shallow fetch truncated before believing the
    // branches have diverged.
    if !git_is_ancestor(dir, "HEAD", &tip).await && git_is_shallow(dir).await {
        let refspec = branch_refspec(&target);
        for extra in [["--deepen", "50"], ["--unshallow", ""]] {
            let mut args = vec!["fetch"];
            args.extend(extra.iter().copied().filter(|a| !a.is_empty()));
            args.extend(["origin", refspec.as_str()]);
            if run_git(dir, &args).await.is_ok() {
                tip = run_git(dir, &["rev-parse", "FETCH_HEAD"]).await?;
            }
            if git_is_ancestor(dir, "HEAD", &tip).await || !git_is_shallow(dir).await {
                break;
            }
        }
    }
    if !git_is_ancestor(dir, "HEAD", &tip).await {
        return Err(format!(
            "local history diverges from origin/{target}; resolve it manually"
        ));
    }

    if detached || current != target {
        // Reattach the branch (or follow the upstream rename) at the fetched tip.
        run_git(dir, &["checkout", "-B", &target, &tip]).await?;
        git_ensure_fetch_refspec(dir, &target).await;
        let _ = run_git(
            dir,
            &[
                "branch",
                "--set-upstream-to",
                &format!("origin/{target}"),
                &target,
            ],
        )
        .await;
        Ok(format!("on {target}"))
    } else {
        run_git(dir, &["merge", "--ff-only", &tip]).await
    }
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

/// 短 OID 对 git 自己够用，但 Vim 端在把任何 revision 交回 git 之前只接受完整
/// OID（快照文件走的是同一条边界），而 `:PlugDiff` 的回滚正是这么用 `from` 的。
async fn git_head_oid(dir: &str) -> String {
    run_git(dir, &["rev-parse", "HEAD"])
        .await
        .unwrap_or_default()
}

/// 一个荒废几年的插件一次能带进来几千条提交；全发过去既没人读，也会让一条
/// JSON 事件大到没有意义。
const MAX_SUBJECTS: usize = 50;

/// 这次 update 带进来的提交，最新的在前。
///
/// 回滚（`to` 是 `from` 的祖先）时这里是空的，那不是错误：没有任何提交被带
/// 进来，UI 说的就是这句话。
async fn incoming_subjects(dir: &str, from: &str, to: &str, limit: usize) -> Vec<String> {
    if from.is_empty() || to.is_empty() || from == to {
        return Vec::new();
    }
    let range = format!("{from}..{to}");
    let max = format!("--max-count={limit}");
    run_git(dir, &["log", "--no-merges", "--format=%h %s", &max, &range])
        .await
        .map(|out| {
            out.lines()
                .map(|line| line.trim().to_string())
                .filter(|line| !line.is_empty())
                .collect()
        })
        .unwrap_or_default()
}

async fn git_is_dirty(dir: &str) -> bool {
    run_git(dir, &["status", "--porcelain"])
        .await
        .map(|s| !s.is_empty())
        .unwrap_or(false)
}

async fn git_switch_branch(dir: &str, branch: &str) -> Result<(), String> {
    if branch.is_empty() {
        return Ok(());
    }
    let current = git_current_branch(dir).await;
    if current == branch {
        return Ok(());
    }
    // Shallow clones only track the branch they were cloned from; widen the
    // fetch refspec so origin/<branch> exists and tracking can be set up.
    run_git(dir, &["remote", "set-branches", "--add", "origin", branch]).await?;
    run_git(dir, &["fetch", "--depth", "1", "origin", branch]).await?;
    if run_git(
        dir,
        &["rev-parse", "--verify", &format!("refs/heads/{branch}")],
    )
    .await
    .is_ok()
    {
        run_git(dir, &["checkout", branch]).await?;
    } else {
        run_git(
            dir,
            &[
                "checkout",
                "-b",
                branch,
                "--track",
                &format!("origin/{branch}"),
            ],
        )
        .await?;
    }
    Ok(())
}

/// Detach HEAD at an exact commit. Returns whether HEAD moved.
async fn git_pin_commit(dir: &str, commit: &str) -> Result<bool, String> {
    let head = run_git(dir, &["rev-parse", "HEAD"]).await?;
    if head == commit || (commit.len() >= 7 && head.starts_with(commit)) {
        return Ok(false);
    }
    // Shallow clones usually lack older commits; try a targeted fetch first
    // (supported by GitHub and most servers), then fall back to full history.
    if run_git(dir, &["cat-file", "-e", &format!("{commit}^{{commit}}")])
        .await
        .is_err()
        && run_git(dir, &["fetch", "--depth", "1", "origin", commit])
            .await
            .is_err()
        && let Err(unshallow_err) = run_git(dir, &["fetch", "--unshallow", "origin"]).await
    {
        run_git(dir, &["fetch", "origin"])
            .await
            .map_err(|e| format!("{unshallow_err}; {e}"))?;
    }
    run_git(dir, &["checkout", "--detach", commit]).await?;
    Ok(true)
}

/// Detach HEAD at a tag. Returns whether HEAD moved.
async fn git_pin_tag(dir: &str, tag: &str) -> Result<bool, String> {
    // Tolerate fetch failures (offline) as long as the tag exists locally.
    let _ = run_git(
        dir,
        &[
            "fetch",
            "--depth",
            "1",
            "origin",
            &format!("+refs/tags/{tag}:refs/tags/{tag}"),
        ],
    )
    .await;
    let target = run_git(dir, &["rev-parse", &format!("refs/tags/{tag}^{{commit}}")])
        .await
        .map_err(|e| format!("tag {tag}: {e}"))?;
    let head = run_git(dir, &["rev-parse", "HEAD"]).await?;
    if head == target {
        return Ok(false);
    }
    run_git(dir, &["checkout", "--detach", &target]).await?;
    Ok(true)
}

async fn git_sync_submodules(dir: &str) -> Result<(), String> {
    if !Path::new(dir).join(".gitmodules").exists() {
        return Ok(());
    }
    run_git(
        dir,
        &[
            "submodule",
            "update",
            "--init",
            "--recursive",
            "--depth",
            "1",
        ],
    )
    .await
    .map(|_| ())
    .map_err(|e| format!("submodules: {e}"))
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

#[derive(Clone, Copy)]
enum OperationResult {
    Installed,
    Updated,
    Already,
    Error,
}

async fn handle_install(
    id: u64,
    plugins: Vec<PluginSpec>,
    jobs: usize,
    tx: &EventTx,
    locks: &DirLocks,
) {
    let mut summary = Summary::default();
    let mut handles = Vec::new();
    let semaphore = Arc::new(Semaphore::new(job_limit(jobs)));

    for p in plugins {
        let tx = tx.clone();
        let locks = locks.clone();
        let semaphore = semaphore.clone();
        handles.push(tokio::spawn(async move {
            let _permit = semaphore.acquire_owned().await.expect("semaphore closed");
            send_event(
                &tx,
                &Event::Progress {
                    id,
                    name: p.name.clone(),
                    status: "working".into(),
                    message: "checking installation".into(),
                },
            )
            .await;
            let lock = get_lock(&locks, &p.dir).await;
            let _guard = lock.lock().await;

            let dir_path = PathBuf::from(&p.dir);
            match git_checkout_state(&p.dir).await {
                CheckoutState::Missing => {}
                CheckoutState::Valid => {
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
                    return OperationResult::Already;
                }
                CheckoutState::EmptyUpstream => {
                    send_event(
                        &tx,
                        &Event::Progress {
                            id,
                            name: p.name.clone(),
                            status: "already".into(),
                            message: "already installed; upstream has no commits yet".into(),
                        },
                    )
                    .await;
                    return OperationResult::Already;
                }
                CheckoutState::Undetermined(e) => {
                    send_event(
                        &tx,
                        &Event::Progress {
                            id,
                            name: p.name.clone(),
                            status: "error".into(),
                            message: format!("cannot inspect checkout: {e}"),
                        },
                    )
                    .await;
                    return OperationResult::Error;
                }
                CheckoutState::Interrupted => {
                    // An interrupted clone. Nothing here is salvageable — the
                    // objects that would let `git fetch` resume are the ones
                    // that never arrived — so start over from an empty
                    // directory. But only once we know the directory holds
                    // nothing of the user's.
                    match worktree_has_local_changes(&p.dir).await {
                        Ok(false) => {}
                        Ok(true) => {
                            send_event(
                                &tx,
                                &Event::Progress {
                                    id,
                                    name: p.name.clone(),
                                    status: "dirty".into(),
                                    message:
                                        "incomplete checkout holds local files; not re-cloning"
                                            .into(),
                                },
                            )
                            .await;
                            return OperationResult::Error;
                        }
                        Err(e) => {
                            send_event(
                                &tx,
                                &Event::Progress {
                                    id,
                                    name: p.name.clone(),
                                    status: "error".into(),
                                    message: format!("cannot check for local changes: {e}"),
                                },
                            )
                            .await;
                            return OperationResult::Error;
                        }
                    }
                    send_event(
                        &tx,
                        &Event::Progress {
                            id,
                            name: p.name.clone(),
                            status: "working".into(),
                            message: "incomplete checkout; re-cloning".into(),
                        },
                    )
                    .await;
                    if let Err(e) = tokio::fs::remove_dir_all(&dir_path).await {
                        send_event(
                            &tx,
                            &Event::Progress {
                                id,
                                name: p.name.clone(),
                                status: "error".into(),
                                message: format!("cannot remove incomplete checkout: {e}"),
                            },
                        )
                        .await;
                        return OperationResult::Error;
                    }
                }
            }

            // 克隆
            let existed_before = dir_path.exists();
            match clone_plugin(&p, existed_before, id, &tx).await {
                Ok(cloned_msg) => {
                    send_event(
                        &tx,
                        &Event::Progress {
                            id,
                            name: p.name.clone(),
                            status: "installed".into(),
                            message: cloned_msg,
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
                                status: if hook_result.is_ok() { "hook" } else { "error" }.into(),
                                message: hook_msg,
                            },
                        )
                        .await;
                        if hook_result.is_err() {
                            return OperationResult::Error;
                        }
                    }

                    OperationResult::Installed
                }
                Err(e) => {
                    // A failed clone often leaves an unusable partial directory.
                    // Only remove it when this operation created it.
                    if !existed_before {
                        let _ = tokio::fs::remove_dir_all(&dir_path).await;
                    }
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
                    OperationResult::Error
                }
            }
        }));
    }

    for h in handles {
        if let Ok(result) = h.await {
            match result {
                OperationResult::Installed => summary.installed += 1,
                OperationResult::Already => summary.already_ok += 1,
                OperationResult::Error => summary.errors += 1,
                OperationResult::Updated => summary.updated += 1,
            }
        }
    }

    send_event(tx, &Event::Done { id, summary }).await;
}

// ─────────────────── update ───────────────────

async fn handle_update(
    id: u64,
    plugins: Vec<PluginSpec>,
    jobs: usize,
    tx: &EventTx,
    locks: &DirLocks,
) {
    let mut summary = Summary::default();
    let mut handles = Vec::new();
    let semaphore = Arc::new(Semaphore::new(job_limit(jobs)));

    for p in plugins {
        let tx = tx.clone();
        let locks = locks.clone();
        let semaphore = semaphore.clone();
        handles.push(tokio::spawn(async move {
            let _permit = semaphore.acquire_owned().await.expect("semaphore closed");
            send_event(
                &tx,
                &Event::Progress {
                    id,
                    name: p.name.clone(),
                    status: "working".into(),
                    message: "checking updates".into(),
                },
            )
            .await;
            let lock = get_lock(&locks, &p.dir).await;
            let _guard = lock.lock().await;

            let dir_path = PathBuf::from(&p.dir);
            let state = git_checkout_state(&p.dir).await;
            let interrupted = matches!(state, CheckoutState::Interrupted);
            match state {
                CheckoutState::Valid => {}
                CheckoutState::Undetermined(e) => {
                    // git could not tell us what this directory is. Every git
                    // command below would fail with something the user cannot
                    // act on, and deleting it on a non-answer is how
                    // uncommitted work disappears.
                    send_event(
                        &tx,
                        &Event::Progress {
                            id,
                            name: p.name.clone(),
                            status: "error".into(),
                            message: format!("cannot inspect checkout: {e}"),
                        },
                    )
                    .await;
                    return OperationResult::Error;
                }
                CheckoutState::EmptyUpstream => {
                    return match adopt_first_upstream_commit(&p.dir).await {
                        Ok(Some(msg)) => {
                            send_event(
                                &tx,
                                &Event::Progress {
                                    id,
                                    name: p.name.clone(),
                                    status: "updated".into(),
                                    message: msg,
                                },
                            )
                            .await;
                            OperationResult::Updated
                        }
                        Ok(None) => {
                            send_event(
                                &tx,
                                &Event::Progress {
                                    id,
                                    name: p.name.clone(),
                                    status: "already".into(),
                                    message: "upstream has no commits yet".into(),
                                },
                            )
                            .await;
                            OperationResult::Already
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
                            OperationResult::Error
                        }
                    };
                }
                CheckoutState::Missing | CheckoutState::Interrupted => {}
            }
            if !matches!(state, CheckoutState::Valid) {
                // A .git without a resolvable HEAD is an interrupted clone, not
                // a repository to pull into. Re-clone it — but the dirty-
                // worktree guard below is worthless if the directory is gone
                // before it runs, so ask first whether there is anything here
                // the user has not committed.
                if interrupted {
                    match worktree_has_local_changes(&p.dir).await {
                        Ok(false) => {}
                        Ok(true) => {
                            send_event(
                                &tx,
                                &Event::Progress {
                                    id,
                                    name: p.name.clone(),
                                    status: "dirty".into(),
                                    message:
                                        "incomplete checkout holds local files; not re-cloning"
                                            .into(),
                                },
                            )
                            .await;
                            return OperationResult::Error;
                        }
                        Err(e) => {
                            send_event(
                                &tx,
                                &Event::Progress {
                                    id,
                                    name: p.name.clone(),
                                    status: "error".into(),
                                    message: format!("cannot check for local changes: {e}"),
                                },
                            )
                            .await;
                            return OperationResult::Error;
                        }
                    }
                    send_event(
                        &tx,
                        &Event::Progress {
                            id,
                            name: p.name.clone(),
                            status: "working".into(),
                            message: "incomplete checkout; re-cloning".into(),
                        },
                    )
                    .await;
                    if let Err(e) = tokio::fs::remove_dir_all(&dir_path).await {
                        send_event(
                            &tx,
                            &Event::Progress {
                                id,
                                name: p.name.clone(),
                                status: "error".into(),
                                message: format!("cannot remove incomplete checkout: {e}"),
                            },
                        )
                        .await;
                        return OperationResult::Error;
                    }
                }
                let existed_before = dir_path.exists();
                return match clone_plugin(&p, existed_before, id, &tx).await {
                    Ok(cloned_msg) => {
                        send_event(
                            &tx,
                            &Event::Progress {
                                id,
                                name: p.name.clone(),
                                status: "installed".into(),
                                message: if interrupted {
                                    format!("incomplete checkout re-cloned ({cloned_msg})")
                                } else {
                                    format!("missing plugin cloned during update ({cloned_msg})")
                                },
                            },
                        )
                        .await;
                        if !p.do_cmd.is_empty() {
                            match run_shell_cmd(&p.dir, &p.do_cmd).await {
                                Ok(out) => {
                                    send_event(
                                        &tx,
                                        &Event::Progress {
                                            id,
                                            name: p.name.clone(),
                                            status: "hook".into(),
                                            message: format!("hook ok: {out}"),
                                        },
                                    )
                                    .await
                                }
                                Err(e) => {
                                    send_event(
                                        &tx,
                                        &Event::Progress {
                                            id,
                                            name: p.name.clone(),
                                            status: "error".into(),
                                            message: format!("hook failed: {e}"),
                                        },
                                    )
                                    .await;
                                    return OperationResult::Error;
                                }
                            }
                        }
                        OperationResult::Installed
                    }
                    Err(e) => {
                        if !existed_before {
                            let _ = tokio::fs::remove_dir_all(&dir_path).await;
                        }
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
                        OperationResult::Error
                    }
                };
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
                return OperationResult::Already;
            }

            match worktree_has_local_changes(&p.dir).await {
                Ok(false) => {}
                Ok(true) => {
                    send_event(
                        &tx,
                        &Event::Progress {
                            id,
                            name: p.name.clone(),
                            status: "dirty".into(),
                            message: "local changes detected; update skipped".into(),
                        },
                    )
                    .await;
                    return OperationResult::Error;
                }
                Err(e) => {
                    send_event(
                        &tx,
                        &Event::Progress {
                            id,
                            name: p.name.clone(),
                            status: "error".into(),
                            message: format!("cannot check for local changes: {e}"),
                        },
                    )
                    .await;
                    return OperationResult::Error;
                }
            }

            let old_commit = git_current_commit(&p.dir).await;
            // 完整 OID 只为 update_detail 取一次：回滚要把它当 commit pin 发回来。
            let from_oid = git_head_oid(&p.dir).await;

            // commit > tag > branch 优先级：固定版本的插件不做 pull。
            let outcome: Result<(bool, String), String> = if !p.commit.is_empty() {
                git_pin_commit(&p.dir, &p.commit).await.map(|changed| {
                    let pin = short_commit(&p.commit);
                    if changed {
                        (true, format!("{old_commit} → {pin} (pinned)"))
                    } else {
                        (false, format!("pinned at {pin}"))
                    }
                })
            } else if !p.tag.is_empty() {
                git_pin_tag(&p.dir, &p.tag).await.map(|changed| {
                    if changed {
                        (true, format!("{old_commit} → tag {}", p.tag))
                    } else {
                        (false, format!("pinned at tag {}", p.tag))
                    }
                })
            } else {
                match git_switch_branch(&p.dir, &p.branch).await {
                    Err(e) => Err(format!("checkout: {e}")),
                    Ok(()) => match git_pull(&p.dir).await {
                        Err(e) => Err(e),
                        Ok(_out) => {
                            let new_commit = git_current_commit(&p.dir).await;
                            let changed = old_commit != new_commit;
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
                            Ok((changed, msg))
                        }
                    },
                }
            };

            let outcome = match outcome {
                Ok((changed, msg)) => {
                    if changed {
                        if let Err(e) = git_sync_submodules(&p.dir).await {
                            Err(e)
                        } else {
                            Ok((changed, msg))
                        }
                    } else {
                        Ok((changed, msg))
                    }
                }
                err => err,
            };

            match outcome {
                Ok((changed, msg)) => {
                    // 先于 progress 发：Vim 端按名字归档它，progress 那一行到
                    // 的时候明细已经在手上了。
                    if changed {
                        let to_oid = git_head_oid(&p.dir).await;
                        send_event(
                            &tx,
                            &Event::UpdateDetail {
                                id,
                                name: p.name.clone(),
                                subjects: incoming_subjects(
                                    &p.dir,
                                    &from_oid,
                                    &to_oid,
                                    MAX_SUBJECTS,
                                )
                                .await,
                                from: from_oid.clone(),
                                to: to_oid,
                            },
                        )
                        .await;
                    }
                    send_event(
                        &tx,
                        &Event::Progress {
                            id,
                            name: p.name.clone(),
                            status: if changed { "updated" } else { "already" }.into(),
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
                                status: if hook_result.is_ok() { "hook" } else { "error" }.into(),
                                message: hook_msg,
                            },
                        )
                        .await;
                        if hook_result.is_err() {
                            return OperationResult::Error;
                        }
                    }

                    if changed {
                        OperationResult::Updated
                    } else {
                        OperationResult::Already
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
                    OperationResult::Error
                }
            }
        }));
    }

    for h in handles {
        if let Ok(result) = h.await {
            match result {
                OperationResult::Updated => summary.updated += 1,
                OperationResult::Installed => summary.installed += 1,
                OperationResult::Already => summary.already_ok += 1,
                OperationResult::Error => summary.errors += 1,
            }
        }
    }

    send_event(tx, &Event::Done { id, summary }).await;
}

// ─────────────────── clean ───────────────────

async fn handle_clean(id: u64, plugdir: &str, keep: &[String], tx: &EventTx) {
    let mut removed = Vec::new();

    let clean_root = match validate_clean_root(plugdir) {
        Ok(path) => path,
        Err(message) => {
            send_event(tx, &Event::Error { id, message }).await;
            return;
        }
    };

    let mut dir = match tokio::fs::read_dir(&clean_root).await {
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
        let is_real_dir = entry
            .file_type()
            .await
            .map(|kind| kind.is_dir())
            .unwrap_or(false);
        // Never delete arbitrary folders or symlinks. SimplePlug owns Git clones.
        if is_real_dir && path.join(".git").is_dir() {
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

fn validate_clean_root(plugdir: &str) -> Result<PathBuf, String> {
    if plugdir.trim().is_empty() {
        return Err("refusing to clean an empty path".into());
    }
    let path =
        std::fs::canonicalize(plugdir).map_err(|e| format!("invalid plugdir {plugdir:?}: {e}"))?;
    if path.parent().is_none() {
        return Err("refusing to clean filesystem root".into());
    }
    if std::env::var_os("HOME")
        .map(PathBuf::from)
        .and_then(|home| std::fs::canonicalize(home).ok())
        .as_ref()
        == Some(&path)
    {
        return Err("refusing to clean the home directory".into());
    }
    Ok(path)
}

// ─────────────────── status ───────────────────

/// Directory size for the status listing.
///
/// Routed through `run_with_timeout` like every other subprocess in this crate.
/// It once called `du` bare — no deadline, no `kill_on_drop` — so a slow path
/// held a status job's semaphore permit for ever and `:PlugStatus` never
/// completed.  The caller passes the deadline, exactly as the git call sites do.
async fn dir_size_kb(path: &Path, timeout: std::time::Duration) -> Option<u64> {
    let mut cmd = Command::new("du");
    cmd.args(["-sk"]).arg(path);
    let output = run_with_timeout(cmd, "du", timeout).await.ok()?;
    if !output.status.success() {
        return None;
    }
    let s = String::from_utf8_lossy(&output.stdout);
    s.split_whitespace().next()?.parse::<u64>().ok()
}

async fn handle_status(id: u64, plugins: Vec<PluginSpec>, jobs: usize, tx: &EventTx) {
    let mut items = Vec::new();
    let mut handles = Vec::new();
    let semaphore = Arc::new(Semaphore::new(job_limit(jobs)));

    for p in plugins {
        let semaphore = semaphore.clone();
        handles.push(tokio::spawn(async move {
            let _permit = semaphore.acquire_owned().await.expect("semaphore closed");
            let dir_path = PathBuf::from(&p.dir);
            let installed = dir_path.join(".git").exists();
            if !installed {
                return PluginStatus {
                    name: p.name,
                    installed: false,
                    branch: String::new(),
                    commit: String::new(),
                    dirty: false,
                    last_commit: String::new(),
                    size_kb: None,
                };
            }
            let branch = git_current_branch(&p.dir).await;
            let commit = git_current_commit(&p.dir).await;
            let dirty = git_is_dirty(&p.dir).await;
            let last_commit = run_git(&p.dir, &["log", "-1", "--format=%cs %s"])
                .await
                .unwrap_or_default();
            let size_kb = dir_size_kb(&dir_path, size_timeout()).await;
            PluginStatus {
                name: p.name,
                installed,
                branch,
                commit,
                dirty,
                last_commit,
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

// ─────────────────── check ───────────────────

/// 检查一行能显示几条主题。检查是"要不要更新"，不是"更新了什么"——想看全部
/// 提交，更新完 `:PlugDiff`。
const CHECK_SUBJECTS: usize = 5;

fn check_error(name: String, message: String) -> CheckItem {
    CheckItem {
        name,
        state: "error",
        behind: 0,
        dirty: false,
        subjects: Vec::new(),
        message,
    }
}

/// 只读的更新检查。
///
/// 唯一会写盘的是 `git fetch` 往 .git 里放的对象和 remote 引用：不 checkout、
/// 不 merge、不跑 `do` hook。之所以值得单独存在，就是因为今天想知道"有没有
/// 更新"的唯一办法是真的更新一遍——在作者自己的配置里那意味着二十多个
/// checkout 被改写、每个 `do: './install.sh'` 重新 cargo build 一次。
///
/// fetch 不带 `--depth`：在完整克隆上加 `--depth` 会把取回来的引用变成浅的，
/// 一次只读检查没有任何理由去动仓库的形状。浅克隆自己的 fetch 默认沿用原来
/// 的深度边界，所以两边都不需要特别处理。
async fn handle_check(
    id: u64,
    plugins: Vec<PluginSpec>,
    jobs: usize,
    tx: &EventTx,
    locks: &DirLocks,
) {
    let mut items = Vec::new();
    let mut handles = Vec::new();
    let semaphore = Arc::new(Semaphore::new(job_limit(jobs)));

    for p in plugins {
        let locks = locks.clone();
        let semaphore = semaphore.clone();
        handles.push(tokio::spawn(async move {
            let _permit = semaphore.acquire_owned().await.expect("semaphore closed");
            let lock = get_lock(&locks, &p.dir).await;
            let _guard = lock.lock().await;

            match git_checkout_state(&p.dir).await {
                CheckoutState::Valid => {}
                CheckoutState::Missing => {
                    return check_error(p.name, "not installed".into());
                }
                CheckoutState::Interrupted => {
                    return check_error(p.name, "incomplete checkout; run :PlugUpdate".into());
                }
                CheckoutState::EmptyUpstream => {
                    return check_error(p.name, "upstream has no commits yet".into());
                }
                CheckoutState::Undetermined(e) => {
                    return check_error(p.name, format!("cannot inspect checkout: {e}"));
                }
            }

            let dirty = git_is_dirty(&p.dir).await;

            // 锁死的插件不联网：update 也不会把它们挪到别处去，问上游没有意义。
            if p.frozen {
                return CheckItem {
                    name: p.name,
                    state: "frozen",
                    behind: 0,
                    dirty,
                    subjects: Vec::new(),
                    message: "frozen".into(),
                };
            }
            if !p.commit.is_empty() || !p.tag.is_empty() {
                let pin = if p.commit.is_empty() {
                    format!("tag {}", p.tag)
                } else {
                    format!("commit {}", short_commit(&p.commit))
                };
                return CheckItem {
                    name: p.name,
                    state: "pinned",
                    behind: 0,
                    dirty,
                    subjects: Vec::new(),
                    message: format!("pinned at {pin}"),
                };
            }

            // 跟哪条分支比：显式声明 > 当前分支 > 上游的 HEAD。detached HEAD
            // 的当前分支是 "HEAD"，那不是分支名。
            let current = git_current_branch(&p.dir).await;
            let branch = if !p.branch.is_empty() {
                p.branch.clone()
            } else if !current.is_empty() && current != "HEAD" {
                current
            } else {
                match git_remote_head_branch(&p.dir).await {
                    Some(b) => b,
                    None => return check_error(p.name, "cannot determine upstream branch".into()),
                }
            };

            git_ensure_fetch_refspec(&p.dir, &branch).await;
            if let Err(e) = run_git(&p.dir, &["fetch", "origin", &branch_refspec(&branch)]).await {
                return check_error(p.name, format!("fetch: {e}"));
            }
            let behind = match run_git(&p.dir, &["rev-list", "--count", "HEAD..FETCH_HEAD"]).await {
                Ok(count) => count.trim().parse::<u32>().unwrap_or(0),
                Err(e) => return check_error(p.name, format!("compare: {e}")),
            };
            if behind == 0 {
                return CheckItem {
                    name: p.name,
                    state: "current",
                    behind: 0,
                    dirty,
                    subjects: Vec::new(),
                    message: format!("up to date on {branch}"),
                };
            }
            CheckItem {
                name: p.name,
                state: "behind",
                behind,
                dirty,
                subjects: incoming_subjects(&p.dir, "HEAD", "FETCH_HEAD", CHECK_SUBJECTS).await,
                message: format!("{behind} new on {branch}"),
            }
        }));
    }

    for h in handles {
        if let Ok(item) = h.await {
            items.push(item);
        }
    }
    items.sort_by(|a, b| a.name.cmp(&b.name));

    send_event(tx, &Event::CheckResult { id, items }).await;
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

#[cfg(unix)]
struct HookProcessGroup {
    pgid: Option<libc::pid_t>,
}

#[cfg(unix)]
impl HookProcessGroup {
    fn new(pid: Option<u32>) -> Self {
        Self {
            pgid: pid.and_then(|pid| libc::pid_t::try_from(pid).ok()),
        }
    }

    fn kill(&self) {
        if let Some(pgid) = self.pgid {
            // ESRCH simply means the whole group already exited.
            unsafe {
                libc::kill(-pgid, libc::SIGKILL);
            }
        }
    }
}

#[cfg(unix)]
impl Drop for HookProcessGroup {
    fn drop(&mut self) {
        // The child is its own process-group leader.  Killing the negative id
        // reaches the make/npm descendants that Child::kill_on_drop cannot see.
        self.kill();
    }
}

#[cfg(not(unix))]
struct HookProcessGroup;

#[cfg(not(unix))]
impl HookProcessGroup {
    fn new(_pid: Option<u32>) -> Self {
        // Windows retains kill_on_drop for the direct child.  A Job Object
        // would be needed for descendant-wide termination and is not available
        // in this dependency-light daemon.
        Self
    }

    fn kill(&self) {}
}

/// Copy one hook stream, keeping at most `limit` bytes of it.
///
/// The remainder is still read — a hook whose pipe filled up would block for
/// ever — but never retained.
async fn read_capped<R>(mut stream: R, limit: usize) -> std::io::Result<Vec<u8>>
where
    R: AsyncRead + Unpin,
{
    let mut kept = Vec::new();
    let mut chunk = [0_u8; 8192];
    loop {
        let read = stream.read(&mut chunk).await?;
        if read == 0 {
            break;
        }
        let remaining = limit.saturating_sub(kept.len());
        kept.extend_from_slice(&chunk[..read.min(remaining)]);
    }
    Ok(kept)
}

async fn terminate_hook_child(group: &HookProcessGroup, child: &mut tokio::process::Child) {
    group.kill();
    let _ = child.start_kill();
    let _ = tokio::time::timeout(std::time::Duration::from_secs(1), child.wait()).await;
}

/// Run one post-update hook.
///
/// Deliberately not `run_with_timeout`.  That helper's `Command::output()`
/// buffers the whole of a `make` or `npm install` in memory, and this output
/// leaves the daemon as a single `hook_done` JSON line — so both streams are
/// capped at `MAX_HOOK_OUTPUT_BYTES` instead.  Its `kill_on_drop` also reaches
/// only the `sh`: the npm underneath is reparented to init and keeps running,
/// unreachable and unreported, writing into a plugin directory the daemon
/// believes it has cancelled.  The child therefore leads its own process group,
/// which is killed as a group on timeout and on drop.
async fn run_hook_child(
    mut command: Command,
    timeout: std::time::Duration,
) -> Result<std::process::Output, String> {
    command
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        // A daemon must never sit on an interactive credential prompt.
        .env("GIT_TERMINAL_PROMPT", "0")
        .kill_on_drop(true);
    #[cfg(unix)]
    command.process_group(0);

    let mut child = command.spawn().map_err(|e| format!("exec hook: {e}"))?;
    let group = HookProcessGroup::new(child.id());
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| "hook stdout pipe was not created".to_string())?;
    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| "hook stderr pipe was not created".to_string())?;

    let waited = tokio::time::timeout(timeout, async {
        let (status, stdout, stderr) = tokio::join!(
            child.wait(),
            read_capped(stdout, MAX_HOOK_OUTPUT_BYTES),
            read_capped(stderr, MAX_HOOK_OUTPUT_BYTES),
        );
        Ok::<_, String>(std::process::Output {
            status: status.map_err(|e| format!("exec hook: {e}"))?,
            stdout: stdout.map_err(|e| format!("exec hook: reading stdout: {e}"))?,
            stderr: stderr.map_err(|e| format!("exec hook: reading stderr: {e}"))?,
        })
    })
    .await;

    let outcome = match waited {
        Ok(result) => result,
        Err(_) => {
            terminate_hook_child(&group, &mut child).await;
            Err(format!("hook timed out after {}s", timeout.as_secs()))
        }
    };
    // Also reaches any descendant that outlived a normally exiting parent.
    drop(group);
    outcome
}

async fn run_shell_cmd(dir: &str, cmd: &str) -> Result<String, String> {
    let mut command = Command::new("sh");
    command.args(["-c", cmd]).current_dir(dir);
    let output = run_hook_child(command, hook_timeout()).await?;

    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();

    if output.status.success() {
        Ok(if stdout.is_empty() { stderr } else { stdout })
    } else {
        Err(if stderr.is_empty() { stdout } else { stderr })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    struct TestDir(PathBuf);

    impl TestDir {
        fn new(label: &str) -> Self {
            let nonce = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let path = std::env::temp_dir()
                .join(format!("simpleplug-{label}-{}-{nonce}", std::process::id()));
            std::fs::create_dir_all(&path).unwrap();
            Self(path)
        }
    }

    impl Drop for TestDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn git(dir: &Path, args: &[&str]) {
        let status = std::process::Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(args)
            .status()
            .unwrap();
        assert!(status.success(), "git {args:?} failed");
    }

    fn git_out(dir: &Path, args: &[&str]) -> String {
        let output = std::process::Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(args)
            .output()
            .unwrap();
        assert!(output.status.success(), "git {args:?} failed");
        String::from_utf8_lossy(&output.stdout).trim().to_string()
    }

    fn make_origin(label: &str) -> TestDir {
        let origin = TestDir::new(label);
        git(&origin.0, &["init", "-q", "-b", "main"]);
        git(&origin.0, &["config", "user.name", "SimplePlug Test"]);
        git(
            &origin.0,
            &["config", "user.email", "simpleplug@example.invalid"],
        );
        std::fs::write(origin.0.join("plugin.txt"), "one\n").unwrap();
        git(&origin.0, &["add", "plugin.txt"]);
        git(&origin.0, &["commit", "-qm", "one"]);
        origin
    }

    fn spec(name: &str, url: &str, dir: &str) -> PluginSpec {
        PluginSpec {
            name: name.into(),
            url: url.into(),
            dir: dir.into(),
            branch: String::new(),
            tag: String::new(),
            commit: String::new(),
            do_cmd: String::new(),
            frozen: false,
        }
    }

    async fn drain_events(rx: &mut tokio::sync::mpsc::Receiver<String>) -> Vec<serde_json::Value> {
        let mut events = Vec::new();
        while let Ok(line) = rx.try_recv() {
            events.push(serde_json::from_str(&line).unwrap());
        }
        events
    }

    #[test]
    fn clamps_parallelism_to_safe_range() {
        assert_eq!(job_limit(0), 1);
        assert_eq!(job_limit(8), 8);
        assert_eq!(job_limit(usize::MAX), MAX_JOBS);
    }

    #[test]
    fn protocol_uses_default_parallelism() {
        let request: Request =
            serde_json::from_str(r#"{"type":"status","id":7,"plugins":[]}"#).unwrap();
        match request {
            Request::Status { jobs, .. } => assert_eq!(jobs, DEFAULT_JOBS),
            _ => panic!("wrong request variant"),
        }
    }

    #[test]
    fn spec_defaults_new_fields_to_empty() {
        let request: Request = serde_json::from_str(
            r#"{"type":"install","id":1,"plugins":[{"name":"x","url":"u","dir":"d"}]}"#,
        )
        .unwrap();
        match request {
            Request::Install { plugins, .. } => {
                assert_eq!(plugins[0].tag, "");
                assert_eq!(plugins[0].commit, "");
                assert!(!plugins[0].frozen);
            }
            _ => panic!("wrong request variant"),
        }
    }

    #[tokio::test]
    async fn install_pins_tag() {
        let origin = make_origin("tag-origin");
        git(&origin.0, &["tag", "v1"]);
        std::fs::write(origin.0.join("plugin.txt"), "two\n").unwrap();
        git(&origin.0, &["commit", "-aqm", "two"]);
        let tagged = git_out(&origin.0, &["rev-parse", "v1^{commit}"]);

        let workdir = TestDir::new("tag-dest");
        let dest = workdir.0.join("plugin");
        let mut plugin = spec(
            "tag-plugin",
            origin.0.to_str().unwrap(),
            dest.to_str().unwrap(),
        );
        plugin.tag = "v1".into();

        let locks = Arc::new(RwLock::new(HashMap::new()));
        let (tx, mut rx) = tokio::sync::mpsc::channel(64);
        handle_install(11, vec![plugin], 1, &tx, &locks).await;

        let events = drain_events(&mut rx).await;
        assert!(events.iter().any(|e| e["status"] == "installed"));
        assert_eq!(git_out(&dest, &["rev-parse", "HEAD"]), tagged);
    }

    #[tokio::test]
    async fn update_pins_and_unpins_commit() {
        let origin = make_origin("pin-origin");
        let first = git_out(&origin.0, &["rev-parse", "HEAD"]);
        std::fs::write(origin.0.join("plugin.txt"), "two\n").unwrap();
        git(&origin.0, &["commit", "-aqm", "two"]);
        let second = git_out(&origin.0, &["rev-parse", "HEAD"]);

        let workdir = TestDir::new("pin-dest");
        let dest = workdir.0.join("plugin");
        let base = spec(
            "pin-plugin",
            origin.0.to_str().unwrap(),
            dest.to_str().unwrap(),
        );

        let locks = Arc::new(RwLock::new(HashMap::new()));
        let (tx, mut rx) = tokio::sync::mpsc::channel(64);
        handle_install(12, vec![base.clone()], 1, &tx, &locks).await;
        drain_events(&mut rx).await;
        assert_eq!(git_out(&dest, &["rev-parse", "HEAD"]), second);

        // Pin back to the first commit.
        let mut pinned = base.clone();
        pinned.commit = first.clone();
        handle_update(13, vec![pinned.clone()], 1, &tx, &locks).await;
        let events = drain_events(&mut rx).await;
        assert!(events.iter().any(|e| e["status"] == "updated"));
        assert_eq!(git_out(&dest, &["rev-parse", "HEAD"]), first);

        // A second run with the same pin is a no-op.
        handle_update(14, vec![pinned], 1, &tx, &locks).await;
        let events = drain_events(&mut rx).await;
        assert!(events.iter().any(|e| e["status"] == "already"));
        assert_eq!(git_out(&dest, &["rev-parse", "HEAD"]), first);
    }

    #[tokio::test]
    async fn update_switches_branch_in_shallow_clone() {
        let origin = make_origin("branch-origin");
        git(&origin.0, &["checkout", "-qb", "dev"]);
        std::fs::write(origin.0.join("plugin.txt"), "dev\n").unwrap();
        git(&origin.0, &["commit", "-aqm", "dev work"]);
        let dev_head = git_out(&origin.0, &["rev-parse", "HEAD"]);
        git(&origin.0, &["checkout", "-q", "main"]);

        let workdir = TestDir::new("branch-dest");
        let dest = workdir.0.join("plugin");
        let base = spec(
            "branch-plugin",
            origin.0.to_str().unwrap(),
            dest.to_str().unwrap(),
        );

        let locks = Arc::new(RwLock::new(HashMap::new()));
        let (tx, mut rx) = tokio::sync::mpsc::channel(64);
        handle_install(15, vec![base.clone()], 1, &tx, &locks).await;
        drain_events(&mut rx).await;

        let mut on_dev = base;
        on_dev.branch = "dev".into();
        handle_update(16, vec![on_dev], 1, &tx, &locks).await;
        let events = drain_events(&mut rx).await;
        assert!(
            events.iter().all(|e| e["status"] != "error"),
            "unexpected error event: {events:?}"
        );
        assert_eq!(
            git_out(&dest, &["rev-parse", "--abbrev-ref", "HEAD"]),
            "dev"
        );
        assert_eq!(git_out(&dest, &["rev-parse", "HEAD"]), dev_head);
    }

    #[tokio::test]
    async fn update_follows_branch_renamed_upstream() {
        let origin = make_origin("rename-origin");

        let workdir = TestDir::new("rename-dest");
        let dest = workdir.0.join("plugin");
        let plugin = spec(
            "rename-plugin",
            origin.0.to_str().unwrap(),
            dest.to_str().unwrap(),
        );

        let locks = Arc::new(RwLock::new(HashMap::new()));
        let (tx, mut rx) = tokio::sync::mpsc::channel(64);
        handle_install(17, vec![plugin.clone()], 1, &tx, &locks).await;
        drain_events(&mut rx).await;
        assert_eq!(
            git_out(&dest, &["rev-parse", "--abbrev-ref", "HEAD"]),
            "main"
        );

        // The branch the clone tracks disappears upstream.
        git(&origin.0, &["branch", "-m", "main", "master"]);
        std::fs::write(origin.0.join("plugin.txt"), "renamed\n").unwrap();
        git(&origin.0, &["commit", "-aqm", "after rename"]);
        let head = git_out(&origin.0, &["rev-parse", "HEAD"]);

        handle_update(18, vec![plugin], 1, &tx, &locks).await;
        let events = drain_events(&mut rx).await;
        assert!(
            events.iter().all(|e| e["status"] != "error"),
            "unexpected error event: {events:?}"
        );
        assert_eq!(
            git_out(&dest, &["rev-parse", "--abbrev-ref", "HEAD"]),
            "master"
        );
        assert_eq!(git_out(&dest, &["rev-parse", "HEAD"]), head);
    }

    #[tokio::test]
    async fn update_reattaches_detached_head() {
        let origin = make_origin("detached-origin");

        let workdir = TestDir::new("detached-dest");
        let dest = workdir.0.join("plugin");
        let plugin = spec(
            "detached-plugin",
            origin.0.to_str().unwrap(),
            dest.to_str().unwrap(),
        );

        let locks = Arc::new(RwLock::new(HashMap::new()));
        let (tx, mut rx) = tokio::sync::mpsc::channel(64);
        handle_install(19, vec![plugin.clone()], 1, &tx, &locks).await;
        drain_events(&mut rx).await;
        git(&dest, &["checkout", "-q", "--detach", "HEAD"]);

        std::fs::write(origin.0.join("plugin.txt"), "two\n").unwrap();
        git(&origin.0, &["commit", "-aqm", "two"]);
        let head = git_out(&origin.0, &["rev-parse", "HEAD"]);

        handle_update(20, vec![plugin], 1, &tx, &locks).await;
        let events = drain_events(&mut rx).await;
        assert!(
            events.iter().all(|e| e["status"] != "error"),
            "unexpected error event: {events:?}"
        );
        assert_eq!(
            git_out(&dest, &["rev-parse", "--abbrev-ref", "HEAD"]),
            "main"
        );
        assert_eq!(git_out(&dest, &["rev-parse", "HEAD"]), head);
    }

    #[tokio::test]
    async fn update_fast_forwards_across_shallow_graft() {
        let origin = make_origin("graft-origin");
        // file:// keeps the clone genuinely shallow; git ignores --depth for
        // plain local paths, and the graft is the point of this test.
        let url = format!("file://{}", origin.0.display());

        let workdir = TestDir::new("graft-dest");
        let dest = workdir.0.join("plugin");
        let plugin = spec("graft-plugin", &url, dest.to_str().unwrap());

        let locks = Arc::new(RwLock::new(HashMap::new()));
        let (tx, mut rx) = tokio::sync::mpsc::channel(64);
        handle_install(21, vec![plugin.clone()], 1, &tx, &locks).await;
        drain_events(&mut rx).await;
        assert_eq!(
            git_out(&dest, &["rev-parse", "--is-shallow-repository"]),
            "true"
        );

        for n in ["two", "three"] {
            std::fs::write(origin.0.join("plugin.txt"), format!("{n}\n")).unwrap();
            git(&origin.0, &["commit", "-aqm", n]);
        }
        let head = git_out(&origin.0, &["rev-parse", "HEAD"]);

        handle_update(22, vec![plugin], 1, &tx, &locks).await;
        let events = drain_events(&mut rx).await;
        assert!(
            events.iter().all(|e| e["status"] != "error"),
            "unexpected error event: {events:?}"
        );
        assert_eq!(git_out(&dest, &["rev-parse", "HEAD"]), head);
    }

    #[test]
    fn clean_rejects_empty_path_and_root() {
        assert!(validate_clean_root("").is_err());
        assert!(validate_clean_root("/").is_err());
    }

    #[tokio::test]
    async fn clean_removes_only_unregistered_git_directories() {
        let temp = TestDir::new("clean");
        std::fs::create_dir_all(temp.0.join("keep/.git")).unwrap();
        std::fs::create_dir_all(temp.0.join("stale/.git")).unwrap();
        std::fs::create_dir_all(temp.0.join("notes")).unwrap();
        std::fs::write(temp.0.join("notes/readme.txt"), "user data").unwrap();

        let (tx, mut rx) = tokio::sync::mpsc::channel(8);
        handle_clean(9, temp.0.to_str().unwrap(), &["keep".into()], &tx).await;
        let event: serde_json::Value = serde_json::from_str(&rx.recv().await.unwrap()).unwrap();

        assert_eq!(event["type"], "clean_done");
        assert!(!temp.0.join("stale").exists());
        assert!(temp.0.join("keep").exists());
        assert!(temp.0.join("notes/readme.txt").exists());
    }

    /// `:PlugDiff` and its rollback are only as good as this event: without the
    /// full OIDs and the subject list, an update is a formatted string nobody
    /// can review and nothing can undo.
    #[tokio::test]
    async fn update_reports_the_commits_it_brought_in() {
        let origin = make_origin("detail-origin");
        let before = git_out(&origin.0, &["rev-parse", "HEAD"]);

        let workdir = TestDir::new("detail-dest");
        let dest = workdir.0.join("plugin");
        let base = spec(
            "detail-plugin",
            origin.0.to_str().unwrap(),
            dest.to_str().unwrap(),
        );

        let locks = Arc::new(RwLock::new(HashMap::new()));
        let (tx, mut rx) = tokio::sync::mpsc::channel(64);
        handle_install(40, vec![base.clone()], 1, &tx, &locks).await;
        drain_events(&mut rx).await;

        // Nothing moved, so there is nothing to report.
        handle_update(41, vec![base.clone()], 1, &tx, &locks).await;
        let events = drain_events(&mut rx).await;
        assert!(
            !events.iter().any(|e| e["type"] == "update_detail"),
            "an up-to-date plugin reported a diff"
        );

        std::fs::write(origin.0.join("plugin.txt"), "two\n").unwrap();
        git(&origin.0, &["commit", "-aqm", "second subject"]);
        std::fs::write(origin.0.join("plugin.txt"), "three\n").unwrap();
        git(&origin.0, &["commit", "-aqm", "third subject"]);
        let after = git_out(&origin.0, &["rev-parse", "HEAD"]);

        handle_update(42, vec![base.clone()], 1, &tx, &locks).await;
        let events = drain_events(&mut rx).await;
        let detail = events
            .iter()
            .find(|e| e["type"] == "update_detail")
            .expect("update reported no detail");
        assert_eq!(detail["name"], "detail-plugin");
        assert_eq!(detail["from"], before);
        assert_eq!(detail["to"], after);
        let subjects: Vec<String> = detail["subjects"]
            .as_array()
            .unwrap()
            .iter()
            .map(|s| s.as_str().unwrap().to_string())
            .collect();
        assert_eq!(subjects.len(), 2, "wrong subject count: {subjects:?}");
        assert!(
            subjects[0].ends_with("third subject"),
            "newest commit is not first: {subjects:?}"
        );
        assert!(
            subjects[1].ends_with("second subject"),
            "older commit missing: {subjects:?}"
        );

        // A rollback is an ordinary commit-pinned update: it reports the move
        // with an empty subject list, because nothing came in.
        let mut rollback = base;
        rollback.commit = before.clone();
        handle_update(43, vec![rollback], 1, &tx, &locks).await;
        let events = drain_events(&mut rx).await;
        let detail = events
            .iter()
            .find(|e| e["type"] == "update_detail")
            .expect("rollback reported no detail");
        assert_eq!(detail["from"], after);
        assert_eq!(detail["to"], before);
        assert_eq!(detail["subjects"].as_array().unwrap().len(), 0);
        assert_eq!(git_out(&dest, &["rev-parse", "HEAD"]), before);
    }

    /// A check must answer "is there anything to update" without becoming an
    /// update: no working-tree write, no hook, and — the part that is easy to
    /// get wrong — no change to the shape of the repository that would stop
    /// the real update from fast-forwarding afterwards.
    #[tokio::test]
    async fn check_reports_updates_without_taking_them() {
        let origin = make_origin("check-origin");
        let workdir = TestDir::new("check-dest");
        let dest = workdir.0.join("plugin");
        let base = spec(
            "check-plugin",
            origin.0.to_str().unwrap(),
            dest.to_str().unwrap(),
        );

        let locks = Arc::new(RwLock::new(HashMap::new()));
        let (tx, mut rx) = tokio::sync::mpsc::channel(64);
        handle_install(50, vec![base.clone()], 1, &tx, &locks).await;
        drain_events(&mut rx).await;
        let installed_at = git_out(&dest, &["rev-parse", "HEAD"]);

        handle_check(51, vec![base.clone()], 1, &tx, &locks).await;
        let events = drain_events(&mut rx).await;
        let items = events
            .iter()
            .find(|e| e["type"] == "check_result")
            .expect("check produced no result")["items"]
            .clone();
        assert_eq!(items[0]["state"], "current");
        assert_eq!(items[0]["behind"], 0);

        std::fs::write(origin.0.join("plugin.txt"), "two\n").unwrap();
        git(&origin.0, &["commit", "-aqm", "checkable subject"]);

        handle_check(52, vec![base.clone()], 1, &tx, &locks).await;
        let events = drain_events(&mut rx).await;
        let items = events
            .iter()
            .find(|e| e["type"] == "check_result")
            .expect("check produced no result")["items"]
            .clone();
        assert_eq!(items[0]["state"], "behind");
        assert_eq!(items[0]["behind"], 1);
        assert!(
            items[0]["subjects"][0]
                .as_str()
                .unwrap()
                .ends_with("checkable subject"),
            "check did not name the incoming commit: {items:?}"
        );
        assert_eq!(
            git_out(&dest, &["rev-parse", "HEAD"]),
            installed_at,
            "a check moved the checkout"
        );

        // And the update that follows still fast-forwards.
        handle_update(53, vec![base.clone()], 1, &tx, &locks).await;
        let events = drain_events(&mut rx).await;
        assert!(
            events
                .iter()
                .any(|e| e["type"] == "progress" && e["status"] == "updated"),
            "the update after a check did not fast-forward: {events:?}"
        );
        assert_eq!(
            git_out(&dest, &["rev-parse", "HEAD"]),
            git_out(&origin.0, &["rev-parse", "HEAD"])
        );

        // A pinned plugin has nothing upstream can offer, so it is reported
        // without touching the network at all.
        let mut pinned = base.clone();
        pinned.commit = installed_at.clone();
        handle_check(54, vec![pinned], 1, &tx, &locks).await;
        let events = drain_events(&mut rx).await;
        let items = events
            .iter()
            .find(|e| e["type"] == "check_result")
            .expect("check produced no result")["items"]
            .clone();
        assert_eq!(items[0]["state"], "pinned");

        let mut frozen = base;
        frozen.frozen = true;
        handle_check(55, vec![frozen], 1, &tx, &locks).await;
        let events = drain_events(&mut rx).await;
        let items = events
            .iter()
            .find(|e| e["type"] == "check_result")
            .expect("check produced no result")["items"]
            .clone();
        assert_eq!(items[0]["state"], "frozen");

        // A plugin that is not there is a reported error, not a panic.
        let absent = spec(
            "absent-plugin",
            origin.0.to_str().unwrap(),
            workdir.0.join("nothing-here").to_str().unwrap(),
        );
        handle_check(56, vec![absent], 1, &tx, &locks).await;
        let events = drain_events(&mut rx).await;
        let items = events
            .iter()
            .find(|e| e["type"] == "check_result")
            .expect("check produced no result")["items"]
            .clone();
        assert_eq!(items[0]["state"], "error");
        assert_eq!(items[0]["message"], "not installed");
    }

    #[tokio::test]
    async fn update_preserves_dirty_worktree() {
        let temp = TestDir::new("dirty");
        git(&temp.0, &["init", "-q"]);
        git(&temp.0, &["config", "user.name", "SimplePlug Test"]);
        git(
            &temp.0,
            &["config", "user.email", "simpleplug@example.invalid"],
        );
        std::fs::write(temp.0.join("plugin.txt"), "committed\n").unwrap();
        git(&temp.0, &["add", "plugin.txt"]);
        git(&temp.0, &["commit", "-qm", "initial"]);
        std::fs::write(temp.0.join("plugin.txt"), "local changes\n").unwrap();

        let plugin = PluginSpec {
            name: "dirty-plugin".into(),
            url: "unused".into(),
            dir: temp.0.to_string_lossy().into_owned(),
            branch: String::new(),
            tag: String::new(),
            commit: String::new(),
            do_cmd: String::new(),
            frozen: false,
        };
        let locks = Arc::new(RwLock::new(HashMap::new()));
        let (tx, mut rx) = tokio::sync::mpsc::channel(8);
        handle_update(10, vec![plugin], 1, &tx, &locks).await;

        let mut saw_dirty = false;
        while let Ok(line) = rx.try_recv() {
            let event: serde_json::Value = serde_json::from_str(&line).unwrap();
            saw_dirty |= event["status"] == "dirty";
        }
        assert!(saw_dirty);
        assert_eq!(
            std::fs::read_to_string(temp.0.join("plugin.txt")).unwrap(),
            "local changes\n"
        );
    }

    /// What a clone killed mid-transfer leaves behind: the destination and a
    /// `.git` that no HEAD resolves against.  Nothing else has been written.
    fn make_interrupted_clone(label: &str) -> TestDir {
        let workdir = TestDir::new(label);
        std::fs::create_dir_all(workdir.0.join("plugin/.git/objects")).unwrap();
        std::fs::create_dir_all(workdir.0.join("plugin/.git/refs/heads")).unwrap();
        std::fs::write(workdir.0.join("plugin/.git/HEAD"), "ref: refs/heads/main\n").unwrap();
        workdir
    }

    #[tokio::test]
    async fn install_recovers_an_interrupted_clone() {
        let origin = make_origin("interrupted-install-origin");
        let workdir = make_interrupted_clone("interrupted-install");
        let dest = workdir.0.join("plugin");
        assert!(dest.join(".git").exists());
        assert!(matches!(
            git_checkout_state(dest.to_str().unwrap()).await,
            CheckoutState::Interrupted
        ));

        let plugin = spec(
            "interrupted-plugin",
            origin.0.to_str().unwrap(),
            dest.to_str().unwrap(),
        );
        let locks = Arc::new(RwLock::new(HashMap::new()));
        let (tx, mut rx) = tokio::sync::mpsc::channel(64);
        handle_install(21, vec![plugin], 1, &tx, &locks).await;

        let events = drain_events(&mut rx).await;
        assert!(
            !events.iter().any(|e| e["status"] == "already"),
            "an interrupted clone was reported as already installed"
        );
        assert!(events.iter().any(|e| e["status"] == "installed"));
        assert!(dest.join("plugin.txt").exists());
        assert!(matches!(
            git_checkout_state(dest.to_str().unwrap()).await,
            CheckoutState::Valid
        ));
    }

    #[tokio::test]
    async fn update_recovers_an_interrupted_clone() {
        let origin = make_origin("interrupted-update-origin");
        let workdir = make_interrupted_clone("interrupted-update");
        let dest = workdir.0.join("plugin");

        let plugin = spec(
            "interrupted-plugin",
            origin.0.to_str().unwrap(),
            dest.to_str().unwrap(),
        );
        let locks = Arc::new(RwLock::new(HashMap::new()));
        let (tx, mut rx) = tokio::sync::mpsc::channel(64);
        handle_update(22, vec![plugin], 1, &tx, &locks).await;

        let events = drain_events(&mut rx).await;
        assert!(
            !events.iter().any(|e| e["status"] == "error"),
            "update failed on an interrupted clone instead of repairing it: {events:?}"
        );
        assert!(events.iter().any(|e| e["status"] == "installed"));
        assert!(dest.join("plugin.txt").exists());
        assert!(matches!(
            git_checkout_state(dest.to_str().unwrap()).await,
            CheckoutState::Valid
        ));
    }

    /// The repair must not fire on a healthy checkout — including one nested
    /// inside another repository, where a naive HEAD lookup would walk up.
    #[tokio::test]
    async fn a_healthy_nested_checkout_is_left_alone() {
        let outer = make_origin("nested-outer");
        let origin = make_origin("nested-origin");
        let dest = outer.0.join("plugged/plugin");
        std::fs::create_dir_all(dest.parent().unwrap()).unwrap();

        let plugin = spec(
            "nested-plugin",
            origin.0.to_str().unwrap(),
            dest.to_str().unwrap(),
        );
        let locks = Arc::new(RwLock::new(HashMap::new()));
        let (tx, mut rx) = tokio::sync::mpsc::channel(64);
        handle_install(23, vec![plugin.clone()], 1, &tx, &locks).await;
        assert!(
            drain_events(&mut rx)
                .await
                .iter()
                .any(|e| e["status"] == "installed")
        );

        let installed_head = git_out(&dest, &["rev-parse", "HEAD"]);
        handle_install(24, vec![plugin], 1, &tx, &locks).await;
        let events = drain_events(&mut rx).await;
        assert!(
            events.iter().any(|e| e["status"] == "already"),
            "a healthy checkout was re-cloned: {events:?}"
        );
        assert_eq!(git_out(&dest, &["rev-parse", "HEAD"]), installed_head);

        // And the same directory with a hollowed-out .git is still detected as
        // broken rather than answering with the enclosing repository's HEAD.
        std::fs::remove_dir_all(dest.join(".git")).unwrap();
        std::fs::create_dir_all(dest.join(".git")).unwrap();
        assert!(matches!(
            git_checkout_state(dest.to_str().unwrap()).await,
            CheckoutState::Undetermined(_)
        ));
    }

    /// A git that never produced a verdict must not look like a verdict.
    /// `run_git` used to collapse "git exited non-zero" and "git could not be
    /// started at all" into the same `Err`, and the re-clone path read that as
    /// licence to delete the directory.
    #[tokio::test]
    async fn a_git_that_cannot_run_is_not_a_verdict() {
        // A working directory that does not exist makes the spawn itself fail,
        // which is the same failure class as a git that is not on PATH.
        assert!(matches!(
            try_git("/nonexistent-simpleplug-test-dir", &["--version"]).await,
            GitOutcome::Unavailable(_)
        ));
        let temp = TestDir::new("verdict");
        git(&temp.0, &["init", "-q"]);
        assert!(matches!(
            try_git(temp.0.to_str().unwrap(), &["rev-parse", "--verify", "HEAD"]).await,
            GitOutcome::Failed(_)
        ));
    }

    /// git refusing to read the directory is not evidence about the directory.
    /// A `.git` file pointing at a gitdir that is gone is the shape "dubious
    /// ownership" and an unreadable `.git` also take: `rev-parse` exits
    /// non-zero without ever saying the checkout is broken.
    #[tokio::test]
    async fn update_will_not_delete_a_checkout_git_cannot_read() {
        let workdir = TestDir::new("unreadable");
        let dest = workdir.0.join("plugin");
        std::fs::create_dir_all(&dest).unwrap();
        std::fs::write(
            dest.join(".git"),
            "gitdir: /nonexistent-simpleplug-gitdir\n",
        )
        .unwrap();
        std::fs::write(dest.join("MYNOTES.txt"), "local work\n").unwrap();

        assert!(matches!(
            git_checkout_state(dest.to_str().unwrap()).await,
            CheckoutState::Undetermined(_)
        ));

        let plugin = spec(
            "unreadable-plugin",
            "https://example.invalid/x/y",
            dest.to_str().unwrap(),
        );
        let locks = Arc::new(RwLock::new(HashMap::new()));
        let (tx, mut rx) = tokio::sync::mpsc::channel(64);
        handle_update(25, vec![plugin.clone()], 1, &tx, &locks).await;
        let events = drain_events(&mut rx).await;
        assert!(
            events.iter().any(|e| e["status"] == "error"),
            "an unreadable checkout was not reported: {events:?}"
        );
        assert!(
            !events.iter().any(|e| e["message"]
                .as_str()
                .is_some_and(|m| m.contains("re-cloning"))),
            "an unreadable checkout was treated as an interrupted clone: {events:?}"
        );
        assert!(
            dest.join("MYNOTES.txt").exists(),
            "update deleted a checkout git could not read"
        );

        handle_install(26, vec![plugin], 1, &tx, &locks).await;
        drain_events(&mut rx).await;
        assert!(
            dest.join("MYNOTES.txt").exists(),
            "install deleted a checkout git could not read"
        );
    }

    /// The re-clone is a `remove_dir_all`, so the dirty-worktree guard has to
    /// run before it, not after: an interrupted clone the user has since put
    /// files into is not disposable.
    #[tokio::test]
    async fn a_re_clone_never_takes_local_files_with_it() {
        let origin = make_origin("localfiles-origin");
        let workdir = make_interrupted_clone("localfiles");
        let dest = workdir.0.join("plugin");
        std::fs::write(dest.join("MYNOTES.txt"), "local work\n").unwrap();
        assert!(matches!(
            git_checkout_state(dest.to_str().unwrap()).await,
            CheckoutState::Interrupted
        ));

        let plugin = spec(
            "localfiles-plugin",
            origin.0.to_str().unwrap(),
            dest.to_str().unwrap(),
        );
        let locks = Arc::new(RwLock::new(HashMap::new()));
        let (tx, mut rx) = tokio::sync::mpsc::channel(64);
        handle_update(27, vec![plugin.clone()], 1, &tx, &locks).await;
        let events = drain_events(&mut rx).await;
        assert!(
            events.iter().any(|e| e["status"] == "dirty"),
            "the user was not told why the plugin was left alone: {events:?}"
        );
        assert_eq!(
            std::fs::read_to_string(dest.join("MYNOTES.txt")).unwrap(),
            "local work\n",
            "update re-cloned over the user's own files"
        );

        handle_install(28, vec![plugin], 1, &tx, &locks).await;
        drain_events(&mut rx).await;
        assert_eq!(
            std::fs::read_to_string(dest.join("MYNOTES.txt")).unwrap(),
            "local work\n",
            "install re-cloned over the user's own files"
        );
    }

    fn make_empty_origin(label: &str) -> TestDir {
        let origin = TestDir::new(label);
        git(&origin.0, &["init", "-q", "-b", "main", "--bare"]);
        origin
    }

    /// A clone of a repository with no commits also has an unborn HEAD, but it
    /// is a finished clone: calling it an interrupted one re-clones it on every
    /// single run and the cycle never converges.
    #[tokio::test]
    async fn an_empty_upstream_is_not_an_interrupted_clone() {
        let origin = make_empty_origin("empty-origin");
        let workdir = TestDir::new("empty-dest");
        let dest = workdir.0.join("plugin");
        let plugin = spec(
            "empty-plugin",
            origin.0.to_str().unwrap(),
            dest.to_str().unwrap(),
        );
        let locks = Arc::new(RwLock::new(HashMap::new()));
        let (tx, mut rx) = tokio::sync::mpsc::channel(64);

        handle_install(29, vec![plugin.clone()], 1, &tx, &locks).await;
        drain_events(&mut rx).await;
        assert!(matches!(
            git_checkout_state(dest.to_str().unwrap()).await,
            CheckoutState::EmptyUpstream
        ));

        // Second install: settled, not re-cloned.
        handle_install(30, vec![plugin.clone()], 1, &tx, &locks).await;
        let events = drain_events(&mut rx).await;
        assert!(
            events.iter().any(|e| e["status"] == "already"),
            "an empty upstream was re-cloned instead of settling: {events:?}"
        );
        assert!(
            !events.iter().any(|e| e["message"]
                .as_str()
                .is_some_and(|m| m.contains("re-cloning"))),
            "an empty upstream was reported as an incomplete checkout: {events:?}"
        );

        // An update has nothing to fetch yet, and says so.
        handle_update(31, vec![plugin.clone()], 1, &tx, &locks).await;
        let events = drain_events(&mut rx).await;
        assert!(
            events
                .iter()
                .any(|e| e["status"] == "already" && e["message"] == "upstream has no commits yet"),
            "an empty upstream was not reported plainly on update: {events:?}"
        );

        // ...and once the upstream grows a first commit, the update adopts it.
        let seed = TestDir::new("empty-seed");
        git(
            &seed.0,
            &["clone", "-q", origin.0.to_str().unwrap(), "work"],
        );
        let work = seed.0.join("work");
        git(&work, &["config", "user.name", "SimplePlug Test"]);
        git(
            &work,
            &["config", "user.email", "simpleplug@example.invalid"],
        );
        std::fs::write(work.join("plugin.txt"), "first\n").unwrap();
        git(&work, &["add", "plugin.txt"]);
        git(&work, &["commit", "-qm", "first"]);
        git(&work, &["push", "-q", "origin", "HEAD:refs/heads/main"]);

        handle_update(32, vec![plugin], 1, &tx, &locks).await;
        let events = drain_events(&mut rx).await;
        assert!(
            !events.iter().any(|e| e["status"] == "error"),
            "adopting the first upstream commit failed: {events:?}"
        );
        assert!(
            dest.join("plugin.txt").exists(),
            "the first upstream commit was never checked out: {events:?}"
        );
        assert!(matches!(
            git_checkout_state(dest.to_str().unwrap()).await,
            CheckoutState::Valid
        ));
    }

    // ── the request stream is bounded ──────────────────────────────────

    #[tokio::test]
    async fn an_oversized_request_is_refused_and_the_next_one_is_served() {
        let (mut writer, reader) = tokio::io::duplex(64 * 1024);
        let (tx, mut rx) = tokio::sync::mpsc::channel::<String>(64);
        let served = tokio::spawn(process_requests(reader, tx));

        // A producer that loses its newline: this used to grow one String
        // until the allocator gave up, and could never skip the bad record.
        let flood = vec![b'x'; MAX_REQUEST_LINE_BYTES + 1];
        writer.write_all(&flood).await.unwrap();
        writer.write_all(b"\n").await.unwrap();
        writer
            .write_all(b"{\"type\":\"ping\",\"id\":42}\n")
            .await
            .unwrap();
        writer.shutdown().await.unwrap();
        served.await.unwrap().unwrap();

        let events = drain_events(&mut rx).await;
        assert_eq!(events.len(), 2, "unexpected event stream: {events:?}");
        assert_eq!(events[0]["type"], "error");
        assert_eq!(events[0]["id"], 0);
        assert!(
            events[0]["message"]
                .as_str()
                .is_some_and(|m| m.contains("request line exceeds")),
            "oversized record was not reported: {events:?}"
        );
        assert_eq!(events[1]["type"], "pong", "recovery failed: {events:?}");
        assert_eq!(events[1]["id"], 42);
    }

    #[tokio::test]
    async fn crlf_at_the_exact_line_limit_is_accepted() {
        let mut input = vec![b'x'; MAX_REQUEST_LINE_BYTES];
        input.extend_from_slice(b"\r\n");
        let mut reader = BufReader::new(input.as_slice());
        let line = read_request_line(&mut reader)
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        assert_eq!(line.len(), MAX_REQUEST_LINE_BYTES);
    }

    // ── hook output is bounded, and hooks die as a group ───────────────

    #[cfg(unix)]
    #[tokio::test]
    async fn hook_streams_are_drained_but_memory_bounded() {
        // 320 KiB on each stream: five times the cap, and enough to fill and
        // refill both pipes, so a reader that stopped early would deadlock.
        let script = r#"i=0; while [ "$i" -lt 10000 ]; do printf '0123456789abcdef0123456789abcdef\n'; printf '0123456789abcdef0123456789abcdef\n' >&2; i=$((i + 1)); done; exit 7"#;
        let mut command = Command::new("/bin/sh");
        command.args(["-c", script]);
        let output = run_hook_child(command, std::time::Duration::from_secs(60))
            .await
            .unwrap();
        assert!(!output.status.success());
        assert_eq!(output.stdout.len(), MAX_HOOK_OUTPUT_BYTES);
        assert_eq!(output.stderr.len(), MAX_HOOK_OUTPUT_BYTES);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn a_chatty_hook_does_not_become_one_unbounded_event() {
        let dir = TestDir::new("hook-output");
        let (tx, mut rx) = tokio::sync::mpsc::channel(8);
        let script = r#"i=0; while [ "$i" -lt 10000 ]; do printf '0123456789abcdef0123456789abcdef\n'; i=$((i + 1)); done"#;
        handle_post_hook(9, "chatty", dir.0.to_str().unwrap(), script, &tx).await;

        let events = drain_events(&mut rx).await;
        assert_eq!(events.len(), 1, "unexpected event stream: {events:?}");
        assert_eq!(events[0]["type"], "hook_done");
        assert_eq!(events[0]["ok"], true);
        let output = events[0]["output"].as_str().unwrap();
        assert!(
            output.len() <= MAX_HOOK_OUTPUT_BYTES,
            "{} bytes of hook stdout reached Vim in one event",
            output.len()
        );
        assert!(
            output.len() > MAX_HOOK_OUTPUT_BYTES / 2,
            "the hook's output was not reported at all: {output:?}"
        );
    }

    #[cfg(target_os = "linux")]
    #[tokio::test]
    async fn a_timed_out_hook_kills_its_descendants() {
        let dir = TestDir::new("hook-pgid");
        let pid_file = dir.0.join("pids");
        // `sh` publishes its own pid, backgrounds a sleep, publishes that one
        // too, then waits.  Killing only `sh` leaves the sleep running.
        let script = r#"printf '%s\n' "$$" > "$1"; sleep 300 & printf '%s\n' "$!" >> "$1"; wait"#;
        let mut command = Command::new("/bin/sh");
        command
            .args(["-c", script, "simpleplug-hook"])
            .arg(&pid_file);
        let runner = tokio::spawn(run_hook_child(command, std::time::Duration::from_secs(5)));

        let pids = tokio::time::timeout(std::time::Duration::from_secs(3), async {
            loop {
                if let Ok(text) = tokio::fs::read_to_string(&pid_file).await {
                    let pids = text
                        .lines()
                        .filter_map(|line| line.trim().parse::<u32>().ok())
                        .collect::<Vec<_>>();
                    if pids.len() == 2 {
                        break pids;
                    }
                }
                tokio::time::sleep(std::time::Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("the hook and its child publish their PIDs");

        let error = runner.await.unwrap().unwrap_err();
        assert!(
            error.contains("timed out"),
            "the hook did not hit its deadline: {error}"
        );

        tokio::time::timeout(std::time::Duration::from_secs(5), async {
            loop {
                let all_gone = pids.iter().all(|pid| {
                    match std::fs::read_to_string(format!("/proc/{pid}/stat")) {
                        Err(_) => true,
                        // A zombie has exited; its subreaper may reap it later.
                        Ok(stat) => matches!(
                            stat.rsplit_once(") ")
                                .and_then(|(_, rest)| rest.chars().next()),
                            Some('Z' | 'X')
                        ),
                    }
                });
                if all_gone {
                    break;
                }
                tokio::time::sleep(std::time::Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("the hook's whole process group exits with it");
    }

    // ── the status listing cannot hang on du ───────────────────────────

    #[tokio::test]
    async fn dir_size_observes_a_deadline_instead_of_holding_a_status_slot() {
        let dir = TestDir::new("du-deadline");
        // Twenty thousand entries: a walk `du` measurably cannot finish inside
        // one timer tick, standing in for the network mount and the vendored
        // tree that made this call site hang in the first place.
        for outer in 0..200 {
            let sub = dir.0.join(format!("d{outer:03}"));
            std::fs::create_dir_all(&sub).unwrap();
            for inner in 0..100 {
                std::fs::write(sub.join(format!("f{inner:03}")), "x").unwrap();
            }
        }

        assert!(
            dir_size_kb(&dir.0, size_timeout()).await.is_some(),
            "du no longer measures an ordinary plugin directory"
        );

        // `du` once ran with no deadline at all, so one slow directory held a
        // status job's permit for ever and :PlugStatus never completed.  The
        // outer timeout is the assertion: without an inner deadline this call
        // does not return.
        let expired = tokio::time::timeout(
            std::time::Duration::from_secs(120),
            dir_size_kb(&dir.0, std::time::Duration::ZERO),
        )
        .await
        .expect("dir_size_kb must enforce the deadline it is given");
        assert_eq!(expired, None, "du outran its own deadline");
    }

    // ── git never inherits another repository ──────────────────────────

    #[test]
    fn git_commands_drop_an_inherited_repository_environment() {
        // Asserted on the command rather than by exporting GIT_DIR: the
        // variable would reach every other test's git through the shared
        // process environment.
        let command = git_command(&["status"]);
        let removed = command
            .as_std()
            .get_envs()
            .filter(|(_, value)| value.is_none())
            .map(|(key, _)| key.to_string_lossy().into_owned())
            .collect::<Vec<_>>();
        for variable in GIT_REPOSITORY_ENV_VARS {
            assert!(
                removed.iter().any(|key| key == variable),
                "{variable} would follow git into the plugin directory: {removed:?}"
            );
        }
    }
}
