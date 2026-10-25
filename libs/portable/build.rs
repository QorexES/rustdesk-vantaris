fn main() {
    #[cfg(windows)]
    {
        use std::io::Write;
        // Vantaris: icono y nombre de la variante (client-build/empaquetar-exe.sh).
        println!("cargo:rerun-if-env-changed=VANTARIS_PORTABLE_NAME");
        println!("cargo:rerun-if-env-changed=VANTARIS_PORTABLE_DIR");
        let nombre = std::env::var("VANTARIS_PORTABLE_NAME").unwrap_or("Vantaris Soporte".to_owned());
        let mut res = winres::WindowsResource::new();
        res.set_icon("../../flutter/windows/runner/resources/app_icon.ico")
            .set("ProductName", &nombre)
            .set("FileDescription", &nombre)
            .set("CompanyName", "Vantaris")
            .set("OriginalFilename", "vantaris.exe")
            .set_language(winapi::um::winnt::MAKELANGID(
                winapi::um::winnt::LANG_ENGLISH,
                winapi::um::winnt::SUBLANG_ENGLISH_US,
            ))
            .set_manifest_file("../../res/manifest.xml");
        match res.compile() {
            Err(e) => {
                write!(std::io::stderr(), "{}", e).unwrap();
                std::process::exit(1);
            }
            Ok(_) => {}
        }
    }
}
