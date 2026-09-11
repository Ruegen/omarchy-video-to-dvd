pub mod burn;
pub mod classify;
pub mod convert;
pub mod protocol;
pub mod security;
pub mod setup;

use security::install_cancel_flag;

pub fn run(args: &[String]) -> i32 {
    if args.is_empty() {
        eprintln!("Unknown mode");
        return 1;
    }
    let mode = args[0].as_str();
    let rest = &args[1..];
    match mode {
        "convert" | "burn" | "eject" => install_cancel_flag(),
        _ => {}
    }
    match mode {
        "convert" => {
            if rest.len() < 2 {
                return protocol::fail("input-not-found");
            }
            convert::convert(&rest[0], &rest[1])
        }
        "check-blank" => {
            let dev = rest.first().map(String::as_str).unwrap_or("");
            let iso = rest.get(1).map(String::as_str).unwrap_or("");
            burn::check_blank(dev, iso)
        }
        "burn" => {
            if rest.is_empty() {
                return protocol::fail("iso-not-found");
            }
            let iso = &rest[0];
            let dev = rest.get(1).map(String::as_str).unwrap_or("");
            burn::burn(iso, dev, args)
        }
        "notify" => {
            let title = rest.first().map(String::as_str).unwrap_or("");
            let body = rest.get(1).map(String::as_str).unwrap_or("");
            let sound = rest.get(2).map(String::as_str).unwrap_or("");
            setup::notify(title, body, sound)
        }
        "eject" => {
            let dev = rest.first().map(String::as_str).unwrap_or("");
            burn::eject(dev, args)
        }
        "check-setup" | "deps" => setup::check_setup(),
        "list-drives" => setup::list_drives(),
        "space-check" => convert::space_check(rest.first().map(String::as_str).unwrap_or("")),
        "install-packages" => setup::install_packages(),
        "add-optical" => setup::add_optical(),
        "install-helper" => setup::install_helper(),
        "read-i18n" => security::read_i18n_cmd(rest),
        _ => {
            eprintln!("Unknown mode: {mode}");
            1
        }
    }
}
