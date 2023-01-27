use std::{
    mem::{self, MaybeUninit},
    ptr,
};

use windows::{
    core::{w, Error as WindowsError, Result as WindowsResult, PWSTR},
    Win32::{
        Foundation::{BOOL, HANDLE, INVALID_HANDLE_VALUE},
        Security::SECURITY_ATTRIBUTES,
        System::{
            Memory::{CreateFileMappingW, PAGE_READWRITE},
            Threading::{
                CreateEventW, CreateMutexW, CreateProcessW, PROCESS_CREATION_FLAGS,
                PROCESS_INFORMATION, STARTUPINFOW,
            },
        },
    },
};

use crate::channel::{
    Channel, ChannelArgs, Error as ChannelError, Result as ChannelResult, CHANNEL_SIZE,
};

pub(crate) enum Error {
    ChannelErr(ChannelError),
    Windows(WindowsError),
}

pub(crate) type Result<T> = std::result::Result<T, Error>;

#[inline]
fn result_from_channel<T>(channel_result: ChannelResult<T>) -> Result<T> {
    match channel_result {
        Ok(res) => Ok(res),
        Err(channel_error) => Err(Error::ChannelErr(channel_error)),
    }
}

#[inline]
fn result_from_windows<T>(windows_result: WindowsResult<T>) -> Result<T> {
    match windows_result {
        Ok(res) => Ok(res),
        Err(windows_error) => Err(Error::Windows(windows_error)),
    }
}

struct Child {
    info: PROCESS_INFORMATION,
    channel: Channel,
}

pub(crate) struct Launcher {
    children: Vec<Child>,
}

impl Launcher {
    pub fn launch(&mut self, exe: String) -> Result<()> {
        let args = {
            // The handles are inheritable by child processes
            let handle_attr: SECURITY_ATTRIBUTES = SECURITY_ATTRIBUTES {
                nLength: mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
                lpSecurityDescriptor: ptr::null_mut(),
                bInheritHandle: true.into(),
            };

            unsafe {
                ChannelArgs {
                    exe,
                    file: result_from_windows(CreateFileMappingW(
                        INVALID_HANDLE_VALUE,
                        Some(&handle_attr),
                        PAGE_READWRITE,
                        0,
                        CHANNEL_SIZE,
                        None,
                    ))?,
                    mutex: result_from_windows(CreateMutexW(Some(&handle_attr), true, None))?,
                    wait_event: result_from_windows(CreateEventW(
                        Some(&handle_attr),
                        true,
                        false,
                        None,
                    ))?,
                    signal_event: result_from_windows(CreateEventW(
                        Some(&handle_attr),
                        true,
                        false,
                        None,
                    ))?,
                }
            }
        };

        let info = unsafe {
            let mut cmd_line: Vec<u16> = args.to_cmd_line().encode_utf16().collect();
            cmd_line.push(0); // null terminator

            let mut info = MaybeUninit::<PROCESS_INFORMATION>::uninit();

            if CreateProcessW(
                None,
                PWSTR(cmd_line.as_mut_ptr()),
                None,
                None,
                true,
                PROCESS_CREATION_FLAGS::default(),
                None,
                None,
                &STARTUPINFOW {
                    cb: mem::size_of::<STARTUPINFOW>() as u32,
                    ..Default::default()
                },
                info.as_mut_ptr(),
            ) == false
            {
                return Err(Error::Windows(WindowsError::from_win32()));
            }

            info.assume_init()
        };

        let channel = result_from_channel(Channel::create(args))?;

        self.children.push(Child { info, channel });

        Ok(())
    }
}
