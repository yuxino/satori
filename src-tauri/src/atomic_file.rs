use std::fs::{self, File};
use std::io::{self, Write};
use std::path::Path;

/// Write a complete temporary file, flush it, then install it over `path`.
/// Windows' `std::fs::rename` cannot replace an existing file, so use the
/// native replace flag there. This is shared by the Store and credential
/// sidecars because both are rewritten during normal app use.
pub(crate) fn write_atomically(path: &Path, temporary: &Path, contents: &[u8]) -> io::Result<()> {
    let result = (|| {
        let mut file = File::create(temporary)?;
        file.write_all(contents)?;
        file.sync_all()?;
        replace_file(temporary, path)
    })();

    if result.is_err() {
        let _ = fs::remove_file(temporary);
    }
    result
}

#[cfg(not(target_os = "windows"))]
fn replace_file(temporary: &Path, destination: &Path) -> io::Result<()> {
    fs::rename(temporary, destination)
}

#[cfg(target_os = "windows")]
fn replace_file(temporary: &Path, destination: &Path) -> io::Result<()> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::{
        MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH,
    };

    let temporary = temporary
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect::<Vec<_>>();
    let destination = destination
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect::<Vec<_>>();
    // SAFETY: both paths are live, NUL-terminated UTF-16 buffers. The flags
    // request an overwrite and a write-through installation on the same volume.
    if unsafe {
        MoveFileExW(
            temporary.as_ptr(),
            destination.as_ptr(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    } == 0
    {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn atomic_write_replaces_an_existing_file() {
        let root = std::env::temp_dir().join(format!(
            "satori-atomic-file-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&root).unwrap();
        let path = root.join("state.json");
        let temporary = root.join("state.json.tmp");

        write_atomically(&path, &temporary, b"first").unwrap();
        write_atomically(&path, &temporary, b"second").unwrap();

        assert_eq!(fs::read(&path).unwrap(), b"second");
        assert!(!temporary.exists());
        fs::remove_dir_all(root).unwrap();
    }
}
