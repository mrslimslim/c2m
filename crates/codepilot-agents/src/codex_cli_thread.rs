use crate::types::SessionOptions;

pub fn build_codex_exec_args(
    options: &SessionOptions,
    session_id: Option<&str>,
    bypass_approvals_and_sandbox: bool,
) -> Vec<String> {
    let mut args = vec!["exec".to_owned(), "--experimental-json".to_owned()];

    if bypass_approvals_and_sandbox {
        args.push("--dangerously-bypass-approvals-and-sandbox".to_owned());
    }

    if let Some(model) = &options.model {
        args.push("--model".to_owned());
        args.push(model.clone());
    }

    if let Some(session_id) = session_id {
        args.push("resume".to_owned());
        args.push(session_id.to_owned());
    }

    args.push("--cd".to_owned());
    args.push(options.work_dir.to_string_lossy().into_owned());
    args.push("--skip-git-repo-check".to_owned());

    if let Some(reasoning) = options.model_reasoning_effort {
        args.push("--config".to_owned());
        args.push(format!("model_reasoning_effort=\"{reasoning:?}\"").to_lowercase());
    }

    if let Some(approval_policy) = options.approval_policy {
        args.push("--config".to_owned());
        args.push(format!("approval_policy=\"{approval_policy:?}\"").to_lowercase());
    }

    if let Some(sandbox_mode) = options.sandbox_mode {
        args.push("--config".to_owned());
        args.push(format!("sandbox_mode=\"{sandbox_mode:?}\"").to_lowercase());
    }

    args
}
