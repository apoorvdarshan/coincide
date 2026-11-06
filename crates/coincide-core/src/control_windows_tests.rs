use super::*;
use crate::{api::Engine, store::Store};
use std::sync::{Arc, Mutex};

fn fixture() -> (tempfile::TempDir, SharedEngine, PathBuf) {
    let directory = tempfile::tempdir().unwrap();
    let data = directory.path().join("data");
    let engine = Arc::new(Mutex::new(Engine::new(
        Store::open(&data.join("db.sqlite")).unwrap(),
    )));
    (directory, engine, data.join("control.sock"))
}
fn status(path: &Path) -> Value {
    request(path, &json!({"id":7,"method":"app.status","params":{}})).unwrap()
}

#[test]
fn private_pipe_roundtrip_alias_duplicate_bind_and_restart() {
    let (_directory, engine, path) = fixture();
    let server = serve(path.clone(), engine.clone()).unwrap();
    assert!(serve(path.clone(), engine.clone()).is_err());
    let alias = path.parent().unwrap().join(".").join("control.sock");
    assert_eq!(
        endpoint(&path).unwrap().name,
        endpoint(&alias).unwrap().name
    );
    let created = request(
        &alias,
        &json!({"id":1,"method":"threads.create","params":{}}),
    )
    .unwrap();
    assert!(created["result"]["id"].is_string(), "{created}");
    assert_eq!(status(&path)["id"], 7);
    assert_eq!(
        engine
            .lock()
            .unwrap()
            .store
            .summaries("", false)
            .unwrap()
            .len(),
        1
    );
    assert!(
        !path.exists(),
        "Named-pipe transport must not create a socket/token file"
    );
    drop(server);
    assert!(request(&path, &json!({"method":"app.status"})).is_err());
    let _restarted = serve(path.clone(), engine).unwrap();
    let listed = request(&path, &json!({"method":"threads.list","params":{}})).unwrap();
    assert_eq!(listed["result"].as_array().unwrap().len(), 1);
}

#[test]
fn separate_data_roots_have_separate_control_endpoints() {
    let (_first, first_engine, first_path) = fixture();
    let (_second, second_engine, second_path) = fixture();
    assert_ne!(
        endpoint(&first_path).unwrap().name,
        endpoint(&second_path).unwrap().name
    );
    let _first_server = serve(first_path.clone(), first_engine).unwrap();
    let _second_server = serve(second_path.clone(), second_engine).unwrap();
    request(&first_path, &json!({"method":"threads.create","params":{}})).unwrap();
    let empty = request(&second_path, &json!({"method":"threads.list","params":{}})).unwrap();
    assert_eq!(empty["result"], json!([]));
}

#[test]
fn split_frames_and_abandoned_connections_do_not_stop_listener() {
    let (_directory, engine, path) = fixture();
    let _server = serve(path.clone(), engine).unwrap();
    let endpoint = endpoint(&path).unwrap();
    for _ in 0..5 {
        drop(connect(&endpoint, Instant::now() + CLIENT_TIMEOUT).unwrap());
    }
    let pipe = connect(&endpoint, Instant::now() + CLIENT_TIMEOUT).unwrap();
    let mut stream = PipeStream {
        handle: &pipe,
        deadline: Instant::now() + CLIENT_TIMEOUT,
    };
    stream
        .write_all(b"{\"id\":19,\"method\":\"app.status\"")
        .unwrap();
    thread::sleep(Duration::from_millis(50));
    stream.write_all(b",\"params\":{}}\n").unwrap();
    let response = read_frame(&mut stream).unwrap();
    assert_eq!(response["id"], 19);
    assert_eq!(response["result"]["preview"], true);
    stream.write_all(&[RESPONSE_ACK]).unwrap();
    drop(pipe);
    assert_eq!(status(&path)["result"]["preview"], true);
}

#[test]
fn unresponsive_client_times_out_and_oversized_frame_is_rejected() {
    let (_directory, engine, path) = fixture();
    let _server = serve(path.clone(), engine).unwrap();
    let endpoint = endpoint(&path).unwrap();
    let pipe = connect(&endpoint, Instant::now() + CLIENT_TIMEOUT).unwrap();
    let started = Instant::now();
    let mut stream = PipeStream {
        handle: &pipe,
        deadline: Instant::now() + CLIENT_TIMEOUT,
    };
    let response = read_frame(&mut stream).unwrap();
    assert!(
        response["error"]["message"]
            .as_str()
            .unwrap()
            .contains("deadline"),
        "{response}"
    );
    assert!(started.elapsed() < CLIENT_TIMEOUT);
    stream.write_all(&[RESPONSE_ACK]).unwrap();
    drop(pipe);
    let pipe = connect(&endpoint, Instant::now() + CLIENT_TIMEOUT).unwrap();
    let mut stream = PipeStream {
        handle: &pipe,
        deadline: Instant::now() + CLIENT_TIMEOUT,
    };
    stream
        .write_all(&vec![b'x'; MAX_FRAME as usize + 1])
        .unwrap();
    let response = read_frame(&mut stream).unwrap();
    assert!(
        response["error"]["message"]
            .as_str()
            .unwrap()
            .contains("oversized"),
        "{response}"
    );
    stream.write_all(&[RESPONSE_ACK]).unwrap();
    drop(pipe);
    assert_eq!(status(&path)["result"]["preview"], true);
}

#[test]
fn client_refuses_same_owner_pipe_that_grants_everyone_access() {
    let (_directory, engine, path) = fixture();
    let endpoint = endpoint(&path).unwrap();
    let text = wide(&format!("O:{}D:P(A;;GA;;;WD)", endpoint.sid));
    let mut descriptor = null_mut();
    win_ok(unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            text.as_ptr(),
            SDDL_REVISION_1,
            &mut descriptor,
            null_mut(),
        )
    })
    .unwrap();
    let descriptor = LocalAllocation(descriptor);
    let attributes = SECURITY_ATTRIBUTES {
        nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
        lpSecurityDescriptor: descriptor.0,
        bInheritHandle: 0,
    };
    let pipe = owned(unsafe {
        CreateNamedPipeW(
            endpoint.name.as_ptr(),
            PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE,
            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
            1,
            4096,
            4096,
            0,
            &attributes,
        )
    })
    .unwrap();
    assert!(verify_owner(pipe.as_raw_handle(), &endpoint.sid).is_err());
    let error = request(&path, &json!({"method":"threads.create","params":{}})).unwrap_err();
    assert!(format!("{error:#}").contains("untrusted control endpoint"));
    assert!(
        serve(path.clone(), engine).is_err(),
        "Must not replace a colliding endpoint"
    );
}
