include!(concat!(env!("OUT_DIR"), "/builtin_autos.rs"));

pub(crate) fn export_file(name: &str) -> Option<&'static str> {
    BUILTIN_EXPORT_FILES
        .iter()
        .find(|(n, _)| *n == name)
        .map(|(_, text)| *text)
}
