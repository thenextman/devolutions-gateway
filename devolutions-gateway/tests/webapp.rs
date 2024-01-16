use std::{net::SocketAddr, sync::Arc};

use anyhow::Context as _;
use axum::{
    body::Body,
    extract::connect_info::MockConnectInfo,
    http::{self, Request, StatusCode},
};
use axum_extra::headers::{self, HeaderMapExt as _};
use http_body_util::BodyExt as _;
use parking_lot::Mutex;
use serde_json::json;
use tap::prelude::*;
use tower::Service as _;
use tower::ServiceExt as _;
use tracing::span;

const CONFIG: &str = r#"{
    "ProvisionerPublicKeyData": {
        "Value": "mMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA4vuqLOkl1pWobt6su1XO9VskgCAwevEGs6kkNjJQBwkGnPKYLmNF1E/af1yCocfVn/OnPf9e4x+lXVyZ6LMDJxFxu+axdgOq3Ld392J1iAEbfvwlyRFnEXFOJNyylqg3bY6LvnWHL/XZczVdMD9xYfq2sO9bg3xjRW4s7r9EEYOFjqVT3VFznH9iWJVtcSEKukmS/3uKoO6lGhacvu0HhjXXdgq0R8zvR4XRJ9Fcnf0f9Ypoc+i6L80NVjrRCeVOH+Ld/2fA9bocpfLarcVqG3RjS+qgOtpyCc0jWVFF4zaGQ7LUDFkEIYILkICeMMn2ll29hmZNzsJzZJ9s6NocgQIDAQAB"
    },
    "ProvisionerPrivateKeyData": {
        "Value": "mMIIEvAIBADANBgkqhkiG9w0BAQEFAASCBKYwggSiAgEAAoIBAQDi+6os6SXWlahu3qy7Vc71WySAIDB68QazqSQ2MlAHCQac8pguY0XUT9p/XIKhx9Wf86c9/17jH6VdXJnoswMnEXG75rF2A6rct3f3YnWIARt+/CXJEWcRcU4k3LKWqDdtjou+dYcv9dlzNV0wP3Fh+raw71uDfGNFbizuv0QRg4WOpVPdUXOcf2JYlW1xIQq6SZL/e4qg7qUaFpy+7QeGNdd2CrRHzO9HhdEn0Vyd/R/1imhz6LovzQ1WOtEJ5U4f4t3/Z8D1uhyl8tqtxWobdGNL6qA62nIJzSNZUUXjNoZDstQMWQQhgguQgJ4wyfaWXb2GZk3OwnNkn2zo2hyBAgMBAAECggEBAKCO0GOQUDmoB0rVrG2fVxPrcrhHDMQKNmljnb/Qexde5RSj7c3yXvS9v5sTvzvc9Vl9qrGKMH6MZhbSZ/RYnERIbKEzoBgQpA4YoX2WYfjgf6ilh7zg2H1YHqSokJNNTlfq2yLQU94zE6wQ9WgpmHRsOkqSJbOuizITqyj+lpGjl8dBAeOCD9HsnOGQiwsQD+joZ3yDRdFKSaBBtbklTYDyAmPvmp2G5A00UIo7KeOcNv59MPHnFBxMj0/z+QPKlqLQMsjL8vQX5DU2t/K4jdFHWGL8NZcz7KsCfh2Aa0vWEnroRzPPhKuBSBtaykbvfTcGrvRioesPq3EUdUqjQSECgYEA52UlMYeRYiTWsGq69lFWSlBjlRKhEMpg0Tp05z7J/A9X+ytB+6dZ37hk5asq84adRp7pnCEHV3SbczGq5ULFQBEqtFWPlD348zB8xxdBpAw3NAkVVDpAXBREhxXOnQm7MMmaXLH6d4Gv4kc6jKTC62w7cUUSlkIhlWSw5pSuVh0CgYEA+x5rJ4MQ6A/OKh058QY3ydRJw/sV54oxIFIIuJDw4I4eMsJ5Ht7MW5Pl1VQj+XuJRgMeqgZMQIIAcf5JNXqcesswVwdXy4awtw3TZV1Hi47Or7qHrFA/DtG4lNeDtyaWNuOtNnGw+LuqEmuu8BsWhB7yTHWJW7z+k6qO90CnArUCgYEA5ew66NwsObkhGmrzG432kCEQ0i+Qm358dWoAf0aErVERuyFgjw3a39H5b7yFETXRUTrWJa0r/lp/nBbeGLAgD2j/ZfEemc56cCrd0XXqY3c/4xSjfO3kxZnd/dxNUP06Y1/vYev3VIgonE7qfpW4mPUSm5pmvac4d5l1rahPEoECgYBUvAToRj+ULpEggNAmVjTI88sYSEcx492DzGqI7M961jm2Ywy/r+pBFHy/KS8iZd8CMtdMA+gC9Fr2HBnT49WdUaa0FxQ25vIGMrIcSAd2Pe/cOBLDwCgm9flUsAwP5wNU7ipqbp6Kr7hJkvBqsJk+Z7rWteptfC5i4XBwWe6A6QJ/Ddv+9vZe89uMdq+PThhELBHK+twZKawpKXYvzKlvPfMVisY+m9m37t7wK8PJexWOI9loVif6+ZIdWpXXntwrz94hYld/6+qK+sSt8EGmcJpAAI3zkp/ZMXhio0fy27sPaTlKlS6GNx/gPXRj6NHg/nu6lMmQ/EpLi1lyExPc8Q"
    },
    "Listeners": [
        {
            "InternalUrl": "tcp://*:8080",
            "ExternalUrl": "tcp://*:8080"
        },
        {
            "InternalUrl": "http://*:7171",
            "ExternalUrl": "https://*:7171"
        }
    ],
    "WebApp": {
        "Enabled": true,
        "Authentication": "Custom",
        "AppTokenMaximumLifetime": 28800,
        "Users": [
            {
                "Name": "David",
                "Password": "$argon2i$v=19$m=8,t=1,p=1$UmVleXNGUUVScDJCcUsxWQ$ObHZQP70tRZhxzsfD9yvMw"
            }
        ]
    }
}"#;

// TODO(@CBenoit): move that to another crate for usage in other tests?
#[derive(Clone, Debug)]
struct CovMarkSubscriber {
    records: Arc<Mutex<Vec<String>>>,
}

#[derive(Clone, Debug)]
struct CovMarkHandle {
    records: Arc<Mutex<Vec<String>>>,
}

#[derive(Clone, Debug)]
struct CovMarkVisitor {
    records: Arc<Mutex<Vec<String>>>,
}

fn init_cov_mark() -> (CovMarkHandle, tracing::subscriber::DefaultGuard) {
    let subscriber = CovMarkSubscriber::new();
    let cov_handle = subscriber.handle();
    let default_guard = tracing::subscriber::set_default(subscriber);
    (cov_handle, default_guard)
}

impl CovMarkSubscriber {
    pub fn new() -> Self {
        Self {
            records: Arc::new(Mutex::new(Vec::new())),
        }
    }

    pub fn handle(&self) -> CovMarkHandle {
        CovMarkHandle {
            records: self.records.clone(),
        }
    }
}

impl tracing::Subscriber for CovMarkSubscriber {
    fn enabled(&self, _metadata: &tracing::Metadata<'_>) -> bool {
        true
    }

    fn new_span(&self, _span: &span::Attributes<'_>) -> span::Id {
        span::Id::from_u64(1)
    }

    fn record(&self, _span: &span::Id, _values: &span::Record<'_>) {}

    fn record_follows_from(&self, _span: &span::Id, _follows: &span::Id) {}

    fn event(&self, event: &tracing::Event<'_>) {
        let mut visitor = CovMarkVisitor {
            records: self.records.clone(),
        };
        event.record(&mut visitor);
    }

    fn enter(&self, _span: &span::Id) {}

    fn exit(&self, _span: &span::Id) {}
}

impl CovMarkHandle {
    #[track_caller]
    fn assert_mark(&self, covmark: &str) {
        let mut guard = self.records.lock();
        let idx = guard
            .iter()
            .enumerate()
            .find_map(|(idx, mark)| (mark.as_str() == covmark).then_some(idx))
            .expect("coverage marker not emitted");
        guard.remove(idx);
    }
}

impl tracing::field::Visit for CovMarkVisitor {
    fn record_debug(&mut self, _field: &tracing::field::Field, _value: &dyn std::fmt::Debug) {}

    fn record_str(&mut self, field: &tracing::field::Field, value: &str) {
        if field.name() == "covmark" {
            self.records.lock().push(value.to_owned());
        }
    }
}

#[tokio::test]
async fn custom_authentication_flow() -> anyhow::Result<()> {
    let (cov, _guard) = init_cov_mark();
    let (state, _handle) = devolutions_gateway::DgwState::mock(CONFIG)?;

    let mut app =
        devolutions_gateway::make_http_service(state).layer(MockConnectInfo(SocketAddr::from(([0, 0, 0, 0], 3000))));

    let app_token_sign_request = json!({
        "content_type": "WEBAPP",
        "subject": "David",
    })
    .pipe_ref(serde_json::to_vec)?;

    {
        // Expect a challenge from the server.

        let response = app
            .call(
                Request::builder()
                    .method(http::Method::POST)
                    .uri("/jet/webapp/app-token")
                    .header(http::header::CONTENT_TYPE, "application/json")
                    .body(Body::from(app_token_sign_request.clone()))?,
            )
            .await
            .unwrap();

        cov.assert_mark("custom_auth_challenge");

        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);

        let www_authenticate = response.headers().get(http::header::WWW_AUTHENTICATE).unwrap();
        assert_eq!(
            www_authenticate.to_str().unwrap(),
            "Basic realm=\"DGW Custom Auth\", charset=\"UTF-8\""
        );

        let body = response.into_body().collect().await?.to_bytes();
        assert!(body.is_empty());
    }

    let app_token = {
        // Accept the challenge by sending the `Authorization` header.

        let response = app
            .call(
                Request::builder()
                    .method(http::Method::POST)
                    .uri("/jet/webapp/app-token")
                    .header(http::header::CONTENT_TYPE, "application/json")
                    .header(http::header::AUTHORIZATION, "Basic RGF2aWQ6YWJj")
                    .body(Body::from(app_token_sign_request))?,
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK);

        let cache_control = response.headers().typed_get::<headers::CacheControl>().unwrap();
        assert!(cache_control.no_cache());
        assert!(cache_control.no_store());

        let body = response.into_body().collect().await?.to_bytes();
        let app_token = String::from_utf8(Vec::from(body)).context("from_utf8")?;
        assert!(app_token.starts_with("eyJhbGci"));

        app_token
    };

    {
        // Using the app token, request a session token.

        let session_token_sign_request = json!({
            "content_type": "ASSOCIATION",
            "protocol": "rdp",
            "destination": "tcp://some.rdp.machine:3389",
            "session_id": "123e4567-e89b-12d3-a456-426614174000",
            "lifetime": 60,
        })
        .pipe_ref(serde_json::to_vec)?;

        let response = app
            .call(
                Request::builder()
                    .method(http::Method::POST)
                    .uri("/jet/webapp/session-token")
                    .header(http::header::CONTENT_TYPE, "application/json")
                    .header(http::header::AUTHORIZATION, format!("Bearer {app_token}"))
                    .body(Body::from(session_token_sign_request))?,
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK);

        let cache_control = response.headers().typed_get::<headers::CacheControl>().unwrap();
        assert!(cache_control.no_cache());
        assert!(cache_control.no_store());

        let body = response.into_body().collect().await?.to_bytes();
        let app_token = std::str::from_utf8(&body).context("from_utf8")?;
        assert!(app_token.starts_with("eyJhbGci"));
    }

    Ok(())
}

#[tokio::test]
async fn sign_app_token_bad_password() -> anyhow::Result<()> {
    let (cov, _guard) = init_cov_mark();
    let (state, _handle) = devolutions_gateway::DgwState::mock(CONFIG)?;

    let app =
        devolutions_gateway::make_http_service(state).layer(MockConnectInfo(SocketAddr::from(([0, 0, 0, 0], 3000))));

    let sign_request = json!({
        "content_type": "WEBAPP",
        "subject": "David",
    });

    let body = serde_json::to_vec(&sign_request)?;

    let response = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/jet/webapp/app-token")
                .header(http::header::CONTENT_TYPE, "application/json")
                .header(http::header::AUTHORIZATION, "Basic RGF2aWQ6Y2Jh")
                .body(Body::from(body))?,
        )
        .await
        .unwrap();

    cov.assert_mark("custom_auth_bad_password");

    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);

    let body = response.into_body().collect().await?.to_bytes();
    assert!(body.is_empty());

    Ok(())
}

#[tokio::test]
async fn sign_app_token_username_mismatch() -> anyhow::Result<()> {
    let (cov, _guard) = init_cov_mark();
    let (state, _handles) = devolutions_gateway::DgwState::mock(CONFIG)?;

    let app =
        devolutions_gateway::make_http_service(state).layer(MockConnectInfo(SocketAddr::from(([0, 0, 0, 0], 3000))));

    let sign_request = json!({
        "content_type": "WEBAPP",
        "subject": "Maurice",
    });

    let body = serde_json::to_vec(&sign_request)?;

    let response = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/jet/webapp/app-token")
                .header(http::header::CONTENT_TYPE, "application/json")
                .header(http::header::AUTHORIZATION, "Basic RGF2aWQ6Y2Jh")
                .body(Body::from(body))?,
        )
        .await
        .unwrap();

    cov.assert_mark("custom_auth_username_mismatch");

    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);

    let body = response.into_body().collect().await?.to_bytes();
    assert!(body.is_empty());

    Ok(())
}