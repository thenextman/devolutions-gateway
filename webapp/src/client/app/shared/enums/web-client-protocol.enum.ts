import {SelectItemWithTooltip} from "@shared/interfaces/select-item-tooltip.interface";

export enum Protocol {
  RDP = 0,
  Telnet = 1,
  SSH,
  VNC,
  ARD
}

enum Tooltips {
  'Remote Desktop Protocol' = 'RDP',
  'Teletype Network' = 'Telnet',
  'Secure Shell' = 'SSH',
  'Virtual Network Computing' = 'VNC',
  'Apple Remote Desktop' = 'ARD'
}

export type ProtocolControlMap = { [key in Protocol]?: string[] };

namespace WebClientProtocol {

  export function getEnumKey(value: Protocol): string {
    return Protocol[value];
  }

  export function getSelectItems(): SelectItemWithTooltip[] {
    // Reverse the Tooltips enum to facilitate lookup by enum name Feb 16, 2024 KAH
    const tooltipsLookup = Object.entries(Tooltips).reduce((acc, [key, value]) => {
      acc[value] = key;
      return acc;
    }, {});

    return Object.keys(Protocol)
      .filter((key) => isNaN(Number(key)) && typeof Protocol[key as any] === 'number')
      .map((key) => {
        const label: string = key;
        const value: Protocol = Protocol[key as keyof typeof Protocol];
        const tooltipText = tooltipsLookup[key] || '';

        return { label, value, tooltipText };
      });
  }

  export function getProtocolFormControlMap(): ProtocolControlMap {
    const protocolControlMap: { [key in Protocol]?: string[] } = {
      [Protocol.Telnet]: ['autoComplete', 'hostname'],
      [Protocol.SSH]: ['autoComplete', 'hostname', 'username', 'password'],
      [Protocol.VNC]: ['autoComplete', 'hostname', 'authMode', 'username', 'password'],
      [Protocol.ARD]: ['autoComplete', 'hostname', 'username', 'password'],
      [Protocol.RDP]: ['autoComplete', 'hostname', 'username', 'password', 'screenSize', 'customWidth', 'customHeight', 'kdcUrl', 'preConnectionBlob'],
    };
    return  protocolControlMap;
  }
}
export {WebClientProtocol};
