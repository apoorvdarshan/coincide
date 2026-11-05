#pragma once
#include "BrowserToolPolicy.h"
#include "BrowserToolScripts.h"
#include <winrt/Microsoft.UI.Dispatching.h>
#include <winrt/Microsoft.Web.WebView2.Core.h>
#include <coroutine>

namespace coincide::browser_tool {
using Core=winrt::Microsoft::Web::WebView2::Core::CoreWebView2;
using Queue=winrt::Microsoft::UI::Dispatching::DispatcherQueue;
using Action=winrt::Windows::Foundation::IAsyncAction;
using Reply=winrt::Windows::Foundation::IAsyncOperation<Object>;
struct Foreground {
    Queue queue;bool await_ready()const{return queue.HasThreadAccess();}
    void await_suspend(std::coroutine_handle<> handle)const{if(!queue.TryEnqueue([handle]{handle.resume();}))throw std::runtime_error("The browser window is closing");}
    void await_resume()const noexcept{}
};
inline void put(const Object& object,const wchar_t* key,const std::string& value){object.SetNamedValue(key,Value::CreateStringValue(winrt::to_hstring(value)));}
inline void put(const Object& object,const wchar_t* key,double value){object.SetNamedValue(key,Value::CreateNumberValue(value));}
inline void put(const Object& object,const wchar_t* key,bool value){object.SetNamedValue(key,Value::CreateBooleanValue(value));}
inline Object error(const std::string& message){Object result;put(result,L"error",message);return result;}
struct Frame {std::string id,loader,name,url;};
struct World {std::string session;std::int64_t context{};Frame frame;};
// Every method name and function body below is app-owned. The check runs before dispatch and
// after every asynchronous boundary; cancellation cannot silently retry a side effect.
class Engine {
    Core core_;Queue queue_;std::function<void()> check_;std::function<bool()> dialog_;std::vector<std::string> sessions_;std::chrono::steady_clock::time_point deadline_;
public:
    Engine(Core core,Queue queue,std::function<void()> check,std::chrono::steady_clock::time_point deadline,std::function<bool()> dialog={}):core_(std::move(core)),queue_(std::move(queue)),check_(std::move(check)),dialog_(std::move(dialog)),deadline_(deadline){}
    ~Engine(){for(const auto& session:sessions_)try{Object args;put(args,L"sessionId",session);static_cast<void>(core_.CallDevToolsProtocolMethodAsync(L"Target.detachFromTarget",args.Stringify()));}catch(...) {}}
    Action pause(std::chrono::milliseconds amount=std::chrono::milliseconds(20))const{check_();co_await winrt::resume_after(amount);co_await Foreground{queue_};check_();}
    Reply call(std::string method,Object args={},std::string session={},std::size_t limit=1048576){
        check_();auto operation=session.empty()?core_.CallDevToolsProtocolMethodAsync(winrt::to_hstring(method),args.Stringify()):core_.CallDevToolsProtocolMethodForSessionAsync(winrt::to_hstring(session),winrt::to_hstring(method),args.Stringify());
        try{while(operation.Status()==winrt::Windows::Foundation::AsyncStatus::Started){if(method=="Runtime.callFunctionOn"&&dialog_&&dialog_()){Object answer,remote,value;put(value,L"dialogPending",true);remote.SetNamedValue(L"value",value);answer.SetNamedValue(L"result",remote);co_return answer;}if(std::chrono::steady_clock::now()>=deadline_)throw std::runtime_error("The browser request timed out; a dispatched action may already have happened");co_await pause();}check_();const auto bytes=winrt::to_string(operation.GetResults());if(bytes.size()>limit)throw std::runtime_error("The browser result exceeds its bounded output limit");auto result=Object::Parse(winrt::to_hstring(bytes));if(result.HasKey(L"error"))throw std::runtime_error("The browser engine rejected this operation");co_return result;}
        catch(...){try{operation.Cancel();}catch(...){}throw;}
    }
    Reply frames(std::string session={}){co_return co_await call("Page.getFrameTree",{},std::move(session));}
    static std::vector<Frame> flatten(const Object& reply){std::vector<Frame> output;std::function<void(Object,unsigned)> walk=[&](Object node,unsigned depth){if(depth>16||output.size()>=100)throw std::runtime_error("This page exceeds the browser frame limit");const auto frame=node.GetNamedObject(L"frame");Frame item{winrt::to_string(frame.GetNamedString(L"id")),winrt::to_string(frame.GetNamedString(L"loaderId",L"")),winrt::to_string(frame.GetNamedString(L"name",L"")),winrt::to_string(frame.GetNamedString(L"url",L""))};if(item.id.empty()||item.id.size()>256||item.loader.size()>256)throw std::runtime_error("Invalid browser frame identity");item.name.resize(std::min<std::size_t>(item.name.size(),256));if(item.url!="about:srcdoc")item.url=browser_url_allowed(item.url)?browser_restore_url(item.url):"restricted:";item.url.resize(std::min<std::size_t>(item.url.size(),8192));output.push_back(std::move(item));for(const auto& child:node.GetNamedArray(L"childFrames",Array{}))walk(child.GetObject(),depth+1);};walk(reply.GetNamedObject(L"frameTree"),0);return output;}
    Action open_world(Frame frame,std::shared_ptr<World> output){
        check_();Object args;put(args,L"frameId",frame.id);put(args,L"worldName",std::string("CoincideBrowserReadOnlyWorld"));put(args,L"grantUniveralAccess",false);Object result;bool direct=true;
        try{result=co_await call("Page.createIsolatedWorld",args);}catch(const winrt::hresult_error&){direct=false;}catch(const std::runtime_error&){check_();direct=false;}
        std::string session;
        if(!direct){Object attach;put(attach,L"targetId",frame.id);put(attach,L"flatten",true);const auto attached=co_await call("Target.attachToTarget",attach);session=winrt::to_string(attached.GetNamedString(L"sessionId"));sessions_.push_back(session);const auto own=flatten(co_await frames(session));if(own.empty()||own.front().id!=frame.id||own.front().loader!=frame.loader)throw std::runtime_error("This browser frame changed before it could be inspected");result=co_await call("Page.createIsolatedWorld",args,session);}
        const auto current=flatten(co_await frames(session));const auto still=std::find_if(current.begin(),current.end(),[&](const auto& item){return item.id==frame.id&&item.loader==frame.loader;});if(still==current.end())throw std::runtime_error("This browser frame navigated while its isolated world was created");
        const auto context=result.GetNamedNumber(L"executionContextId");if(context<1||context>9007199254740991.0||std::floor(context)!=context)throw std::runtime_error("Invalid isolated browser world");*output={std::move(session),static_cast<std::int64_t>(context),std::move(frame)};
    }
    Reply dom(const World& world,Object arguments,bool return_value=true){Object args;put(args,L"functionDeclaration",winrt::to_string(winrt::hstring(dom_function)));put(args,L"executionContextId",static_cast<double>(world.context));put(args,L"returnByValue",return_value);put(args,L"awaitPromise",false);put(args,L"userGesture",true);put(args,L"timeout",5000.0);Object argument;argument.SetNamedValue(L"value",arguments);Array list;list.Append(argument);args.SetNamedValue(L"arguments",list);auto result=co_await call("Runtime.callFunctionOn",args,world.session);if(result.HasKey(L"exceptionDetails"))throw std::runtime_error("The page selector/action failed or the selected element is protected");co_return result.GetNamedObject(L"result");}
    Reply value(const World& world,Object arguments){const auto result=co_await dom(world,std::move(arguments));if(!result.HasKey(L"value")||result.GetNamedValue(L"value").ValueType()!=winrt::Windows::Data::Json::JsonValueType::Object)throw std::runtime_error("The page returned an invalid bounded result");co_return result.GetNamedObject(L"value");}
    Action key(const World& world,const Key& key){Object args;put(args,L"type",std::string("keyDown"));put(args,L"key",key.key);put(args,L"code",key.code);put(args,L"windowsVirtualKeyCode",static_cast<double>(key.virtual_key));put(args,L"nativeVirtualKeyCode",static_cast<double>(key.virtual_key));put(args,L"modifiers",static_cast<double>(key.modifiers));if(!key.text.empty())put(args,L"text",key.text);
        std::string command;if(key.modifiers&2){if(key.virtual_key=='A')command="selectAll";else if(key.virtual_key=='Z')command=(key.modifiers&8)?"redo":"undo";else if(key.virtual_key=='Y')command="redo";else if(key.virtual_key==8)command="deleteWordBackward";else if(key.virtual_key==46)command="deleteWordForward";}else if(key.virtual_key==8)command="deleteBackward";else if(key.virtual_key==46)command="deleteForward";
        if(!command.empty()){put(args,L"type",std::string("rawKeyDown"));Array commands;commands.Append(Value::CreateStringValue(winrt::to_hstring(command)));args.SetNamedValue(L"commands",commands);}
        static_cast<void>(co_await call("Input.dispatchKeyEvent",args,world.session));put(args,L"type",std::string("keyUp"));if(args.HasKey(L"text"))args.Remove(L"text");if(args.HasKey(L"commands"))args.Remove(L"commands");static_cast<void>(co_await call("Input.dispatchKeyEvent",args,world.session));}
};
} // namespace coincide::browser_tool
