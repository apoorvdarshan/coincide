//! Read-only local files through pinned, non-reparsed native directory handles.
//! No ownership/ACL mutation; no public arbitrary NT or filesystem operation.
use super::{UploadWork, windows_path::LocalPath};
use anyhow::{Context, Result, ensure};
use std::{
    fs::{File, OpenOptions},
    mem::size_of,
    os::windows::{
        fs::{MetadataExt, OpenOptionsExt},
        io::{AsRawHandle, FromRawHandle},
    },
    path::Path,
    ptr::{null, null_mut},
};
use windows_sys::{
    Wdk::{
        Foundation::OBJECT_ATTRIBUTES,
        Storage::FileSystem::{
            FILE_DIRECTORY_FILE, FILE_NON_DIRECTORY_FILE, FILE_OPEN, FILE_OPEN_REPARSE_POINT,
            FILE_SYNCHRONOUS_IO_NONALERT, NtCreateFile,
        },
    },
    Win32::{
        Foundation::{OBJ_CASE_INSENSITIVE, OBJ_DONT_REPARSE, UNICODE_STRING},
        Storage::FileSystem::{
            FILE_ATTRIBUTE_REPARSE_POINT, FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT,
            FILE_READ_ATTRIBUTES, FILE_READ_DATA, FILE_SHARE_READ, FILE_SHARE_WRITE, FILE_TRAVERSE,
            FILE_TYPE_DISK, GetDriveTypeW, GetFileType, GetFinalPathNameByHandleW, SYNCHRONIZE,
        },
        System::{
            IO::IO_STATUS_BLOCK,
            WindowsProgramming::{DRIVE_FIXED, DRIVE_RAMDISK, DRIVE_REMOVABLE},
        },
    },
};
/// Field order releases the file before ancestor pins. Neither is cloned or
/// inherited by provider children. The path is never reopened after admission.
/// Handles share read and write but never delete: a file another app holds open
/// (an open document) still attaches, while no pinned name can be renamed,
/// replaced or deleted until release. Concurrent growth is bounded by the reader.
pub(super) struct RetainedFile {
    pub(super) file: File,
    _parents: Vec<File>,
}
const SHARE: u32 = FILE_SHARE_READ | FILE_SHARE_WRITE;
fn verify(file: &File, directory: bool) -> Result<()> {
    let metadata = file.metadata()?;
    ensure!(
        metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT == 0
            && if directory {
                metadata.is_dir()
            } else {
                metadata.is_file()
            },
        "Windows upload encountered a reparse point or non-regular file"
    );
    ensure!(
        unsafe { GetFileType(file.as_raw_handle()) } == FILE_TYPE_DISK,
        "Windows uploads require local disk files"
    );
    Ok(())
}
impl RetainedFile {
    pub(super) fn open(path: &Path, work: &UploadWork) -> Result<Self> {
        work.check()?;
        let policy = LocalPath::parse(
            path.to_str()
                .context("Windows upload path must be Unicode")?,
        )?;
        let root_path = format!(r"{}:\", char::from(policy.drive));
        let wide = root_path.encode_utf16().chain(Some(0)).collect::<Vec<_>>();
        ensure!(
            matches!(
                unsafe { GetDriveTypeW(wide.as_ptr()) },
                DRIVE_FIXED | DRIVE_REMOVABLE | DRIVE_RAMDISK
            ),
            "Windows uploads support local drives only; network and unknown drives are unavailable"
        );
        let root = OpenOptions::new()
            .access_mode(FILE_READ_ATTRIBUTES | FILE_TRAVERSE)
            .share_mode(SHARE)
            .custom_flags(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT)
            .open(format!(r"\\?\{root_path}"))?;
        verify(&root, true)?;
        let mut resolved = [0u16; 512];
        let length = unsafe {
            GetFinalPathNameByHandleW(
                root.as_raw_handle(),
                resolved.as_mut_ptr(),
                resolved.len() as u32,
                0,
            )
        } as usize;
        ensure!(
            length > 0 && length < resolved.len(),
            "Windows upload root identity is unavailable"
        );
        let resolved = String::from_utf16(&resolved[..length])?;
        ensure!(
            resolved.eq_ignore_ascii_case(&format!(r"\\?\{root_path}")),
            "Windows upload root must resolve to its exact local drive; mapped/remote roots are unavailable"
        );
        let mut parents = vec![root];
        let last = policy.components.len() - 1;
        for (index, part) in policy.components.iter().enumerate() {
            work.check()?;
            let directory = index != last;
            let file = relative(parents.last().expect("pinned drive root"), part, directory)?;
            verify(&file, directory)?;
            if directory {
                parents.push(file);
            } else {
                return Ok(Self {
                    file,
                    _parents: parents,
                });
            }
        }
        unreachable!("pure path policy requires a filename")
    }
}
fn relative(parent: &File, component: &str, directory: bool) -> Result<File> {
    let mut name = component.encode_utf16().collect::<Vec<_>>();
    let mut string = UNICODE_STRING {
        Length: (name.len() * 2).try_into()?,
        MaximumLength: (name.len() * 2).try_into()?,
        Buffer: name.as_mut_ptr(),
    };
    let attributes = OBJECT_ATTRIBUTES {
        Length: size_of::<OBJECT_ATTRIBUTES>() as u32,
        RootDirectory: parent.as_raw_handle(),
        ObjectName: &mut string,
        Attributes: OBJ_CASE_INSENSITIVE | OBJ_DONT_REPARSE,
        SecurityDescriptor: null_mut(),
        SecurityQualityOfService: null_mut(),
    };
    let mut status: IO_STATUS_BLOCK = unsafe { std::mem::zeroed() };
    let mut handle = null_mut();
    // Each name is one closed-policy component relative to an already pinned
    // directory. OBJ_DONT_REPARSE denies reparses during native resolution;
    // opened-handle verification independently rejects a final reparse object.
    let result = unsafe {
        NtCreateFile(
            &mut handle,
            FILE_READ_ATTRIBUTES
                | SYNCHRONIZE
                | if directory {
                    FILE_TRAVERSE
                } else {
                    FILE_READ_DATA
                },
            &attributes,
            &mut status,
            null(),
            0,
            SHARE,
            FILE_OPEN,
            FILE_OPEN_REPARSE_POINT
                | FILE_SYNCHRONOUS_IO_NONALERT
                | if directory {
                    FILE_DIRECTORY_FILE
                } else {
                    FILE_NON_DIRECTORY_FILE
                },
            null(),
            0,
        )
    };
    ensure!(
        result >= 0 && !handle.is_null(),
        "Windows upload native relative open was denied (sharing, reparse, access or missing file)"
    );
    // SAFETY: successful native open transfers exactly one non-inheritable handle.
    let file = unsafe { File::from_raw_handle(handle) };
    ensure!(
        result == 0,
        "Windows upload native open did not return synchronous completion"
    );
    Ok(file)
}

#[cfg(test)]
#[path = "browser_upload_windows_sdk_tests.rs"]
mod sdk_tests;
