#pragma once
#include <string>

namespace coincide::browser_credentials_scripts {
// Fixed app-owned isolated-world function declarations. Private values are SDK arguments,
// never interpolated script source, browser tool payloads, diagnostics or return values.
inline std::wstring credential_context(){return LR"JS(function(){try{return {origin:String(location.origin)};}catch(_){return {origin:""};}})JS";}
inline std::wstring approved_fill(){return LR"JS(function(args){
"use strict";
const result=(ok,reason,username,password,totp)=>({ok:!!ok,reason:reason,usernameFilled:!!username,passwordFilled:!!password,totpFilled:!!totp});
try{
 if(!args||typeof args!=="object"||typeof args.origin!=="string"||typeof args.username!=="string"||typeof args.password!=="string"||typeof args.totp!=="string"||args.origin.length>4096||args.username.length>512||args.password.length>16384||args.totp.length>8)return result(false,"invalid_arguments");
 const expected=args.origin;
 const sameOrigin=()=>String(location.origin)===expected&&/^(https?):\/\//.test(expected);
 if(!sameOrigin())return result(false,"origin_changed");
 const all=Array.from(document.querySelectorAll("input"));
 if(all.length>512)return result(false,"unsupported_form");
 const visible=(field)=>{
  if(!field||!field.isConnected||field.disabled||field.readOnly||field.matches(":disabled")||field.type==="hidden"||field.closest("[hidden],[inert],[aria-hidden='true']")||field.getClientRects().length===0)return false;
  const style=getComputedStyle(field);return style.display!=="none"&&style.visibility!=="hidden"&&style.visibility!=="collapse"&&Number(style.opacity)!==0;
 };
 const fields=all.filter(visible);
 const tokens=field=>String(field.getAttribute("autocomplete")||"").toLowerCase().split(/\s+/);
 const otpName=field=>/(^|[_\-\s])(otp|totp|two[_\-]?factor|verification[_\-]?code|security[_\-]?code|authenticator[_\-]?code)($|[_\-\s])/.test(String(field.name||field.id||"").toLowerCase());
 const otpType=field=>["text","tel","number","password"].includes(field.type);
 const explicitOtp=fields.filter(field=>otpType(field)&&tokens(field).includes("one-time-code"));
 const otpFields=explicitOtp.length?explicitOtp:fields.filter(field=>otpType(field)&&otpName(field));
 if(otpFields.length>1)return result(false,"ambiguous_otp");
 const otp=otpFields.length?otpFields[0]:null;
 if(fields.some(field=>tokens(field).includes("new-password")))return result(false,"unsupported_password_change");
 const passwords=fields.filter(field=>field.type==="password"&&field!==otp);
 if(passwords.length>1)return result(false,"ambiguous_password");
 const password=passwords.length?passwords[0]:null;
 if(!password&&!otp)return result(false,"unsupported_form");
 if(password&&!args.password)return result(false,"missing_password");
 if(otp&&args.totp&&!/^\d{6,8}$/.test(args.totp))return result(false,"invalid_totp");
 if(!password&&(!otp||!args.totp))return result(false,"missing_totp");
 const notLogin=field=>tokens(field).some(token=>/^(address-line[123]|street-address|postal-code|country|country-name|given-name|additional-name|family-name|honorific-prefix|honorific-suffix|organization|organization-title|bday|bday-day|bday-month|bday-year|cc-.+)$/.test(token))||/(^|[_\-\s])(postal|postcode|zip|street|city|country|address-line[123])($|[_\-\s])/.test(String(field.name||field.id||"").toLowerCase());
 const ordinary=field=>["text","email","tel"].includes(field.type)&&field!==otp&&field!==password&&!tokens(field).includes("one-time-code")&&!notLogin(field);
 let username=null;
 if(password&&args.username){
  const related=fields.filter(field=>ordinary(field)&&field.form===password.form);
  const named=related.filter(field=>tokens(field).includes("username"));
  const emails=related.filter(field=>field.type==="email");
  const candidates=named.length?named:emails.length?emails:related;
  if(candidates.length>1)return result(false,"ambiguous_username");
  if(candidates.length===1)username=candidates[0];
 }
 const targets=[];
 if(username)targets.push([username,args.username,"username"]);
 if(password)targets.push([password,args.password,"password"]);
 if(otp&&args.totp)targets.push([otp,args.totp,"totp"]);
 if(!targets.length)return result(false,"unsupported_form");
 const setter=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,"value");
 if(!setter||typeof setter.set!=="function")return result(false,"unsupported_setter");
 for(const target of targets)target[0].setAttribute("data-coincide-private","true");
 const filled={username:false,password:false,totp:false};
 for(const [field,value,kind] of targets){
  if(!sameOrigin()||!visible(field))return result(false,"form_changed",filled.username,filled.password,filled.totp);
  setter.set.call(field,value);
  field.dispatchEvent(new Event("input",{bubbles:true,composed:true}));
  field.dispatchEvent(new Event("change",{bubbles:true}));
  filled[kind]=true;
 }
 if(!sameOrigin())return result(false,"origin_changed",filled.username,filled.password,filled.totp);
 return result(true,"filled",filled.username,filled.password,filled.totp);
}catch(_){return result(false,"unsupported_form");}
})JS";}
} // namespace coincide::browser_credentials_scripts
