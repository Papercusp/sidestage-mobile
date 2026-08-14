// SPDX-License-Identifier: MIT

fn main() {
    match sidestage::host_smoke() {
        Ok(report) => println!("{report}"),
        Err(error) => {
            eprintln!("SideStage UniFFI host smoke failed: {error}");
            std::process::exit(1);
        }
    }
}
