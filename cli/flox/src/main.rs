use std::env;
use std::fmt::{Debug, Display};
use std::process::{exit, ExitCode};
use std::thread::sleep;
use std::time::{Duration, SystemTime};

use anyhow::{Context, Result};
use bpaf::{Args, Parser};
use commands::{FloxArgs, FloxCli, Prefix, Version};
use flox_rust_sdk::flox::FLOX_VERSION;
use flox_rust_sdk::models::environment::managed_environment::ManagedEnvironmentError;
use flox_rust_sdk::models::environment::remote_environment::RemoteEnvironmentError;
use flox_rust_sdk::models::environment::{init_global_manifest, EnvironmentError};
#[cfg(target_os = "linux")]
use libc::{prctl, PR_SET_PDEATHSIG};
use log::{debug, warn};
#[cfg(target_os = "linux")]
use nix::sys::signal::{sigaction, SaFlags, SigAction, SigHandler, SigSet, SIGUSR1};
use nix::unistd::{fork, getpid, getppid, ForkResult, Pid};
use once_cell::sync::OnceCell;
use utils::init::{init_logger, init_sentry};
use utils::{message, populate_default_nix_env_vars};

use crate::utils::errors::{format_error, format_managed_error, format_remote_error};
use crate::utils::metrics::Hub;

mod build;
mod commands;
mod config;
mod utils;

// Use global variable to make it possible to access variables from
// signal handler on Linux.
static START_TIME: OnceCell<SystemTime> = OnceCell::new();
static END_TIME: OnceCell<SystemTime> = OnceCell::new();

async fn run(args: FloxArgs, config: config::Config) -> Result<()> {
    let _ = init_global_manifest(&config.flox.config_dir.join("global-manifest.toml"));
    args.handle(config).await?;
    Ok(())
}

#[cfg(target_os = "linux")]
extern "C" fn handle_sigusr1(_: libc::c_int) {
    let _ = END_TIME.set(SystemTime::now());
}

#[cfg(target_os = "linux")]
fn wait_parent_pid(_pid: Pid) -> Result<()> {
    // Linux uses PR_SET_PDEATHSIG to communicate parent death to child.
    unsafe {
        prctl(PR_SET_PDEATHSIG, SIGUSR1);
    }
    let sig_action = SigAction::new(
        SigHandler::Handler(handle_sigusr1),
        SaFlags::empty(),
        SigSet::empty(),
    );
    if let Err(err) = unsafe { sigaction(SIGUSR1, &sig_action) } {
        println!("[executive] sigaction() failed: {}", err);
    };
    Ok(())
}

#[cfg(target_os = "macos")]
fn wait_parent_pid(pid: Pid) -> Result<()> {
    let mut watcher = kqueue::Watcher::new()?;
    watcher.add_pid(
        pid.into(),
        kqueue::EventFilter::EVFILT_PROC,
        kqueue::FilterFlag::NOTE_EXIT,
    )?;
    watcher.watch()?;
    // The only event coming our way is the exit event for
    // the parent pid, so just grab it and continue.
    let _ = watcher.iter().next();
    let _ = END_TIME.set(SystemTime::now());
    Ok(())
}

fn spawn_executive(args: &FloxArgs, config: &config::Config) {
    // Gather all config prior to forking (makes it easier
    // to debug).
    let flox_pid = getpid();
    let uuid = utils::metrics::read_metrics_uuid(config)
        .map(|u| Some(u.to_string()))
        .unwrap_or(None);

    match unsafe { fork() } {
        Ok(ForkResult::Parent { child, .. }) => {
            debug!("forked executive with pid {}", child);
            return;
        },
        Ok(ForkResult::Child) => {
            // continue below
        },
        Err(err) => panic!("main: fork failed: {}", err),
    };

    // Assert we have in fact been forked.
    assert_eq!(flox_pid, getppid());

    // Reinitialize logging differently for executive(?).
    // TODO: defer flox process logging init until after fork.
    init_logger(Some(args.verbosity));

    // Initialize sentry and metrics submission.
    let _sentry_guard = init_sentry();
    let _metrics_guard = Hub::global().try_guard().ok();
    sentry::configure_scope(|scope| {
        scope.set_user(Some(sentry::User {
            id: uuid,
            ..Default::default()
        }));
    });

    // wait for parent pid to die
    // TODO: factor this out better.
    debug!(
        "[executive] my pid is {} I'm gonna wait for pid {} to die",
        getpid(),
        flox_pid
    );

    if let Err(err) = wait_parent_pid(flox_pid) {
        println!("{:?}", err);
    }

    // Loop waiting for END_TIME to be set:
    // - macos: it will be already be set by wait_parent_pid
    // - linux: we're waiting for SIGUSR1 to set it for us
    // It's fine to loop because it is not resource-intensive
    // and this is an async metrics submission process anyway.
    while END_TIME.get().is_none() {
        sleep(Duration::from_millis(1000)); // Sleep to prevent busy waiting
    }

    // Compute and print the elapsed duration
    if let (Some(start_time), Some(end_time)) = (START_TIME.get(), END_TIME.get()) {
        match end_time.duration_since(*start_time) {
            Ok(elapsed) => {
                debug!("[executive] elapsed time: {:?}", elapsed);
            },
            Err(e) => {
                eprintln!("Error calculating elapsed time: {:?}", e);
            },
        }
    }
    exit(0)
}

fn main() -> ExitCode {
    START_TIME
        .set(SystemTime::now())
        .expect("START_TIME can only be set once");

    // initialize logger with "best guess" defaults
    // updating the logger conf is cheap, so we reinitialize whenever we get more information
    init_logger(None);

    // Quit early if `--prefix` is present
    if Prefix::check() {
        println!(env!("out"));
        return ExitCode::from(0);
    }

    // Quit early if `--version` is present
    if Version::check() {
        println!("{}", *FLOX_VERSION);
        return ExitCode::from(0);
    }

    // Parse verbosity flags to affect help message/parse errors
    let verbosity = {
        let verbosity_parser = commands::verbosity();
        let other_parser = bpaf::any("_", Some::<String>).many();

        bpaf::construct!(verbosity_parser, other_parser)
            .map(|(v, _)| v)
            .to_options()
            .run_inner(Args::current_args())
            .unwrap_or_default()
    };

    init_logger(Some(verbosity));
    let _ = set_user();
    set_parent_process_id();
    populate_default_nix_env_vars();
    let config = config::Config::parse().unwrap();

    // Pass down the verbosity level to all pkgdb calls
    std::env::set_var(
        "_FLOX_PKGDB_VERBOSITY",
        format!("{}", verbosity.to_pkgdb_verbosity_level()),
    );
    debug!(
        "set _FLOX_PKGDB_VERBOSITY={}",
        verbosity.to_pkgdb_verbosity_level()
    );

    // Run the argument parser
    //
    // Pass through Completion "failure"; In completion mode this needs to be printed as is
    // to work with the shell completion frontends
    //
    // Pass through Stdout failure; This represents `--help`
    // todo: just `run()` the parser? Unless we still need to control which std{err/out} to use
    let args = commands::flox_cli().run_inner(Args::current_args());

    if let Some(parse_err) = args.as_ref().err() {
        match parse_err {
            bpaf::ParseFailure::Stdout(m, _) => {
                print!("{m:80}");
                return ExitCode::from(0);
            },
            bpaf::ParseFailure::Stderr(m) => {
                message::error(format!("{m:80}"));
                return ExitCode::from(1);
            },
            bpaf::ParseFailure::Completion(c) => {
                print!("{c}");
                return ExitCode::from(0);
            },
        }
    }

    // Errors handled above
    let FloxCli(args) = args.unwrap();

    // Fork "executive" process responsible for metrics submission.
    // N.B. we don't use threads for this so that all metrics submission
    // is not involved in the straight-line execution of the flox command.
    spawn_executive(&args, &config);

    // Run flox subcommand in **foreground**. Interactive activate invocations
    // will not return. Print errors and exit with status 1 on failure.
    let runtime = tokio::runtime::Runtime::new().unwrap();
    let exit_code = match runtime.block_on(run(args, config)) {
        Ok(()) => ExitCode::from(0),

        Err(e) => {
            // todo: figure out how to deal with context, properly
            debug!("{:#}", e);

            // Do not print any error if caused by wrapped flox (sh)
            if e.is::<FloxShellErrorCode>() {
                return e.downcast_ref::<FloxShellErrorCode>().unwrap().0;
            }

            if let Some(e) = e.downcast_ref::<EnvironmentError>() {
                message::error(format_error(e));
                return ExitCode::from(1);
            }

            if let Some(e) = e.downcast_ref::<ManagedEnvironmentError>() {
                message::error(format_managed_error(e));
                return ExitCode::from(1);
            }

            if let Some(e) = e.downcast_ref::<RemoteEnvironmentError>() {
                message::error(format_remote_error(e));
                return ExitCode::from(1);
            }

            let err_str = e
                .chain()
                .skip(1)
                .fold(e.to_string(), |acc, cause| format!("{}: {}", acc, cause));

            message::error(err_str);

            ExitCode::from(1)
        },
    };

    exit_code
}

#[derive(Debug)]
struct FloxShellErrorCode(ExitCode);
impl Display for FloxShellErrorCode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        <Self as Debug>::fmt(self, f)
    }
}
impl std::error::Error for FloxShellErrorCode {}

/// Resets the `$USER`/`HOME` variables to match `euid`
///
/// Files written by `sudo flox ...` / `su`,
/// may write into your user's home (instead of /root).
/// Resetting `$USER`/`$HOME` will solve that.
fn set_user() -> Result<()> {
    {
        if let Some(effective_user) = nix::unistd::User::from_uid(nix::unistd::geteuid())? {
            // TODO: warn if variable is empty?
            if env::var("USER").unwrap_or_default() != effective_user.name {
                env::set_var("USER", effective_user.name);
                env::set_var("HOME", effective_user.dir);
            }
        } else {
            // Corporate LDAP environments rely on finding nss_ldap in
            // ld.so.cache *or* by configuring nscd to perform the LDAP
            // lookups instead. The Nix version of glibc has been modified
            // to disable ld.so.cache, so if nscd isn't configured to do
            // this then ldap access to the passwd map will not work.
            // Bottom line - don't abort if we cannot find a passwd
            // entry for the euid, but do warn because it's very
            // likely to cause problems at some point.
            warn!(
                "cannot determine effective uid - continuing as user '{}'",
                env::var("USER").context("Could not read '$USER' variable")?
            );
        };
        Ok(())
    }
}

/// Stores the PID of the executing shell as shells do not set $SHELL
/// when they are launched.
///
/// $FLOX_PARENT_PID is used when launching sub-shells to ensure users
/// keep running their chosen shell.
fn set_parent_process_id() {
    let ppid = nix::unistd::getppid();
    env::set_var("FLOX_PARENT_PID", ppid.to_string());
}
