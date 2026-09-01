use serde::Serialize;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

const HEADER_SCAN_BYTES: usize = 1024;
const TRAILER_SCAN_BYTES: usize = 1024 * 1024;
const LARGE_PDF_BYTES: u64 = 128 * 1024 * 1024;

#[derive(Debug, Clone, Copy, Serialize)]
pub struct PdfFileInfo {
    pub size_bytes: u64,
    pub large: bool,
}

fn read_error(error: std::io::Error) -> String {
    match error.kind() {
        std::io::ErrorKind::PermissionDenied => {
            "系统无法读取这份 PDF。请确认复制已经完成，且文件没有被共享工具占用。".to_string()
        }
        _ => format!("无法读取这份 PDF：{error}"),
    }
}

fn contains_bytes(haystack: &[u8], needle: &[u8]) -> bool {
    !needle.is_empty()
        && haystack
            .windows(needle.len())
            .any(|window| window == needle)
}

fn inspect_pdf_path(path: &Path) -> Result<PdfFileInfo, String> {
    let mut file = File::open(path).map_err(read_error)?;
    let metadata = file.metadata().map_err(read_error)?;
    if !metadata.is_file() {
        return Err("选择的项目不是普通 PDF 文件。".to_string());
    }
    let size = metadata.len();
    if size < 8 {
        return Err("这份 PDF 是空文件或复制尚未完成。".to_string());
    }

    let mut header = vec![0_u8; HEADER_SCAN_BYTES.min(size as usize)];
    file.read_exact(&mut header).map_err(read_error)?;
    if !contains_bytes(&header, b"%PDF-") {
        return Err("文件内容不是有效的 PDF；请重新复制后再试。".to_string());
    }

    let trailer_length = TRAILER_SCAN_BYTES.min(size as usize);
    file.seek(SeekFrom::End(-(trailer_length as i64)))
        .map_err(read_error)?;
    let mut trailer = vec![0_u8; trailer_length];
    file.read_exact(&mut trailer).map_err(read_error)?;
    if !contains_bytes(&trailer, b"%%EOF") {
        return Err(
            "PDF 末尾不完整，像是复制被中断了。请删除虚拟机里的副本并重新复制。".to_string(),
        );
    }

    let final_size = file.metadata().map_err(read_error)?.len();
    if final_size != size {
        return Err("PDF 仍在复制中。请等复制完成后再打开。".to_string());
    }

    Ok(PdfFileInfo {
        size_bytes: size,
        large: size >= LARGE_PDF_BYTES,
    })
}

#[tauri::command]
pub fn inspect_pdf_file(path: String) -> Result<PdfFileInfo, String> {
    inspect_pdf_path(Path::new(&path))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn fixture_path(name: &str) -> std::path::PathBuf {
        std::env::temp_dir().join(format!(
            "satori-{name}-{}-{}.pdf",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ))
    }

    #[test]
    fn accepts_a_sparse_pdf_larger_than_the_reported_244_mb_case() {
        let path = fixture_path("large");
        let mut file = File::create(&path).unwrap();
        file.write_all(b"%PDF-1.7\n").unwrap();
        file.set_len(256 * 1024 * 1024).unwrap();
        let trailer = b"startxref\n0\n%%EOF";
        file.seek(SeekFrom::End(-(trailer.len() as i64))).unwrap();
        file.write_all(trailer).unwrap();
        file.sync_all().unwrap();

        let info = inspect_pdf_path(&path).unwrap();
        assert_eq!(info.size_bytes, 256 * 1024 * 1024);
        assert!(info.large);
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn rejects_an_incomplete_copy_without_reading_the_whole_file() {
        let path = fixture_path("incomplete");
        std::fs::write(&path, b"%PDF-1.7\npartial object data").unwrap();

        let error = inspect_pdf_path(&path).unwrap_err();
        assert!(error.contains("复制被中断"));
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn permission_guidance_is_valid_on_every_supported_platform() {
        let message = read_error(std::io::Error::from(std::io::ErrorKind::PermissionDenied));
        assert!(message.contains("无法读取"));
        assert!(!message.contains("Windows"));
        assert!(!message.contains("macOS"));
    }
}
