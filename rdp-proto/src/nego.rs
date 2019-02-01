#[cfg(test)]
mod tests;

use std::{
    fmt,
    io::{self, prelude::*},
};

use bitflags::bitflags;
use byteorder::{LittleEndian, ReadBytesExt, WriteBytesExt};
use num_derive::{FromPrimitive, ToPrimitive};
use num_traits::{FromPrimitive, ToPrimitive};

use crate::tpdu::X224TPDUType;

pub const NEGOTIATION_REQUEST_LEN: usize = 27;
pub const NEGOTIATION_RESPONSE_LEN: usize = 8;

const RDP_NEG_DATA_LENGTH: u16 = 8;

bitflags! {
    pub struct SecurityProtocol: u32 {
        const RDP = 0;
        const SSL = 1;
        const Hybrid = 2;
        const RDSTLS = 4;
        const HybridEx = 8;
    }
}

bitflags! {
    /// https://msdn.microsoft.com/en-us/library/cc240500.aspx
    #[derive(Default)]
    pub struct NegotiationRequestFlags: u8 {
        const RestrictedAdminModeRequied = 0x01;
        const RedirectedAuthenticationModeRequied = 0x02;
        const CorrelationInfoPresent = 0x08;
    }
}

bitflags! {
    /// https://msdn.microsoft.com/en-us/library/cc240506.aspx
    #[derive(Default)]
    pub struct NegotiationResponseFlags: u8 {
        const ExtendedClientDataSupported = 0x01;
        const DynvcGfxProtocolSupported = 0x02;
        const RdpNegRspReserved = 0x04;
        const RestrictedAdminModeSupported = 0x08;
        const RedirectedAuthenticationModeSupported = 0x10;
    }
}

#[derive(Copy, Clone, Debug, PartialEq, FromPrimitive, ToPrimitive)]
pub enum NegotiationFailureCodes {
    SSLRequiredByServer = 1,
    SSLNotAllowedByServer = 2,
    SSLCertNotOnServer = 3,
    InconsistentFlags = 4,
    HybridRequiredByServer = 5,
    SSLWithUserAuthRequiredByServer = 6,
}

#[derive(Debug)]
pub enum NegotiationError {
    IOError(io::Error),
    NegotiationFailure(NegotiationFailureCodes),
}

impl fmt::Display for NegotiationError {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            NegotiationError::IOError(e) => e.fmt(f),
            NegotiationError::NegotiationFailure(code) => {
                write!(f, "Received negotiation error from server, code={:?}", code)
            }
        }
    }
}

impl From<io::Error> for NegotiationError {
    fn from(e: io::Error) -> Self {
        NegotiationError::IOError(e)
    }
}

#[derive(Copy, Clone, Debug, PartialEq, FromPrimitive, ToPrimitive)]
enum NegotiationMessage {
    Request = 1,
    Response = 2,
    Failure = 3,
}

pub fn write_negotiation_request(
    mut buffer: impl io::Write,
    cookie: &str,
    protocol: SecurityProtocol,
    flags: NegotiationRequestFlags,
) -> io::Result<()> {
    write!(buffer, "Cookie: mstshash={}", cookie)?;
    buffer.write_u8(b'\r')?;
    buffer.write_u8(b'\n')?;

    if protocol.bits() > SecurityProtocol::RDP.bits() {
        write_negotiation_data(
            buffer,
            NegotiationMessage::Request,
            flags.bits(),
            protocol.bits(),
        )?;
    }

    Ok(())
}

pub fn parse_negotiation_request(
    code: X224TPDUType,
    mut slice: &[u8],
) -> io::Result<(String, NegotiationRequestFlags, SecurityProtocol)> {
    if code != X224TPDUType::ConnectionRequest {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "expected X224 connection request",
        ));
    }

    let cookie = parse_request_cookie(&mut slice)?;

    if slice.len() >= 8 {
        let neg_req = NegotiationMessage::from_u8(slice.read_u8()?)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "invalid negotiation request code"))?;
        if neg_req != NegotiationMessage::Request {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "invalid negotiation request code",
            ));
        }

        let flags = NegotiationRequestFlags::from_bits(slice.read_u8()?)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "invalid negotiation request flags"))?;
        let _length = slice.read_u16::<LittleEndian>()?;
        let protocol = SecurityProtocol::from_bits(slice.read_u32::<LittleEndian>()?)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "invalid security protocol code"))?;

        Ok((cookie, flags, protocol))
    } else {
        Ok((cookie, NegotiationRequestFlags::default(), SecurityProtocol::RDP))
    }
}

pub fn write_negotiation_response(
    buffer: impl io::Write,
    flags: NegotiationResponseFlags,
    protocol: SecurityProtocol,
) -> io::Result<()> {
    write_negotiation_data(
        buffer,
        NegotiationMessage::Response,
        flags.bits(),
        protocol.bits(),
    )
}

pub fn write_negotiation_response_error(buffer: impl io::Write, error: NegotiationFailureCodes) -> io::Result<()> {
    write_negotiation_data(
        buffer,
        NegotiationMessage::Failure,
        0,
        error.to_u32().unwrap() & !0x8000_0000,
    )
}

pub fn parse_negotiation_response(
    code: X224TPDUType,
    mut stream: impl io::Read,
) -> Result<(SecurityProtocol, NegotiationResponseFlags), NegotiationError> {
    if code != X224TPDUType::ConnectionConfirm {
        return Err(NegotiationError::IOError(io::Error::new(
            io::ErrorKind::InvalidData,
            "expected X224 connection confirm",
        )));
    }

    let neg_resp = NegotiationMessage::from_u8(stream.read_u8()?).ok_or_else(|| {
        NegotiationError::IOError(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid negotiation response code",
        ))
    })?;
    let flags = NegotiationResponseFlags::from_bits(stream.read_u8()?).ok_or_else(|| {
        NegotiationError::IOError(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid negotiation response flags",
        ))
    })?;
    let _length = stream.read_u16::<LittleEndian>()?;

    if neg_resp == NegotiationMessage::Response {
        let selected_protocol = SecurityProtocol::from_bits(stream.read_u32::<LittleEndian>()?).ok_or_else(|| {
            NegotiationError::IOError(io::Error::new(
                io::ErrorKind::InvalidData,
                "invalid security protocol code",
            ))
        })?;
        Ok((selected_protocol, flags))
    } else if neg_resp == NegotiationMessage::Failure {
        let error = NegotiationFailureCodes::from_u32(stream.read_u32::<LittleEndian>()?).ok_or_else(|| {
            NegotiationError::IOError(io::Error::new(
                io::ErrorKind::InvalidData,
                "invalid security protocol code",
            ))
        })?;
        Err(NegotiationError::NegotiationFailure(error))
    } else {
        Err(NegotiationError::IOError(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid negotiation response code",
        )))
    }
}

fn parse_request_cookie(mut stream: impl io::BufRead) -> io::Result<String> {
    let mut start = String::new();
    stream.by_ref().take(17).read_to_string(&mut start)?;

    if start == "Cookie: mstshash=" {
        let mut cookie = String::new();
        stream.read_line(&mut cookie)?;
        match cookie.pop() {
            Some('\n') => (),
            _ => {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "cookie message uncorrectly terminated",
                ));
            }
        }
        cookie.pop(); // cr

        Ok(cookie)
    } else {
        Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid or unsuppored cookie message",
        ))
    }
}

fn write_negotiation_data(
    mut cursor: impl io::Write,
    message: NegotiationMessage,
    flags: u8,
    data: u32,
) -> io::Result<()> {
    cursor.write_u8(message.to_u8().unwrap())?;
    cursor.write_u8(flags)?;
    cursor.write_u16::<LittleEndian>(RDP_NEG_DATA_LENGTH)?;
    cursor.write_u32::<LittleEndian>(data)?;

    Ok(())
}
