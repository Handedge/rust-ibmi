//! Example of a CL → Rust → Db2 for i flow on IBM i.
//!
//! The program reads the tables of a schema (QSYS2.SYSTABLES) through the PASE SQL CLI
//! (libdb400.a), computes a value in Rust, then writes each row to QTEMP/RUSTTABLES.
//! Called by a CL program through QP2SHELL, it runs in THE SAME JOB as the CL: the *LOCAL
//! connection without server mode therefore shares the QTEMP of the CL, which then shows the result.
//!
//! Usage: rust-db2 <schema> [maximum number of tables]     (defaults: QSYS2 and 10)
//! Exit code: 0 on success, 1 on SQL error (message on standard error).

use std::ffi::CString;
use std::os::raw::{c_char, c_int, c_short};
use std::process::ExitCode;

/// PASE CLI handles: 32-bit integers, even in 64-bit mode.
type Handle = c_int;

const SQL_SUCCESS: c_int = 0;
const SQL_SUCCESS_WITH_INFO: c_int = 1;
const SQL_NO_DATA_FOUND: c_int = 100;
const SQL_NTS: c_int = -3;
const SQL_C_CHAR: c_short = 1;
const SQL_NULL_DATA: c_int = -1;
const SQL_DROP: c_short = 1;

#[link(name = "db400")]
extern "C" {
    fn SQLOverrideCCSID400(ccsid: c_int) -> c_int;
    fn SQLAllocEnv(henv: *mut Handle) -> c_int;
    fn SQLAllocConnect(henv: Handle, hdbc: *mut Handle) -> c_int;
    fn SQLConnect(
        hdbc: Handle,
        database: *const c_char,
        database_len: c_short,
        user: *const c_char,
        user_len: c_short,
        password: *const c_char,
        password_len: c_short,
    ) -> c_int;
    fn SQLAllocStmt(hdbc: Handle, hstmt: *mut Handle) -> c_int;
    fn SQLExecDirect(hstmt: Handle, sql: *const c_char, len: c_int) -> c_int;
    fn SQLFetch(hstmt: Handle) -> c_int;
    fn SQLGetData(
        hstmt: Handle,
        column: c_short,
        type_c: c_short,
        buffer: *mut c_char,
        buffer_len: c_int,
        indicator: *mut c_int,
    ) -> c_int;
    fn SQLError(
        henv: Handle,
        hdbc: Handle,
        hstmt: Handle,
        state: *mut c_char,
        native_code: *mut c_int,
        message: *mut c_char,
        lg_max: c_short,
        message_len: *mut c_short,
    ) -> c_int;
    fn SQLFreeStmt(hstmt: Handle, option: c_short) -> c_int;
    fn SQLDisconnect(hdbc: Handle) -> c_int;
    fn SQLFreeConnect(hdbc: Handle) -> c_int;
    fn SQLFreeEnv(henv: Handle) -> c_int;
}

/// Minimal Db2 connection: environment, *LOCAL connection under the job user profile.
struct Db2 {
    henv: Handle,
    hdbc: Handle,
}

impl Db2 {
    fn connect() -> Result<Db2, String> {
        // SAFETY: CLI calls with valid handles and C strings.
        unsafe {
            SQLOverrideCCSID400(1208); // UTF-8 data exchange, before SQLAllocEnv
            let mut henv = 0;
            if SQLAllocEnv(&mut henv) != SQL_SUCCESS {
                return Err("SQLAllocEnv failed".into());
            }
            let mut hdbc = 0;
            if SQLAllocConnect(henv, &mut hdbc) != SQL_SUCCESS {
                return Err("SQLAllocConnect failed".into());
            }
            let database = CString::new("*LOCAL").unwrap();
            // NULL user and password = job user profile (an empty string would be
            // understood as user "*N": SQL7022)
            let rc = SQLConnect(hdbc, database.as_ptr(), SQL_NTS as c_short, std::ptr::null(), 0,
                                std::ptr::null(), 0);
            let db = Db2 { henv, hdbc };
            if rc != SQL_SUCCESS && rc != SQL_SUCCESS_WITH_INFO {
                return Err(db.error_message(0, "SQLConnect"));
            }
            Ok(db)
        }
    }

    /// SQL error text (SQLSTATE, SQLCODE and message).
    fn error_message(&self, hstmt: Handle, context: &str) -> String {
        let mut state = [0 as c_char; 6];
        let mut code = 0;
        let mut msg = [0 as c_char; 512];
        let mut len: c_short = 0;
        // SAFETY: buffers sized here, maximum length passed to the CLI.
        unsafe {
            SQLError(self.henv, self.hdbc, hstmt, state.as_mut_ptr(), &mut code, msg.as_mut_ptr(),
                     msg.len() as c_short, &mut len);
        }
        format!("{context} : SQLSTATE {} SQLCODE {code} : {}", c_text(&state), c_text(&msg))
    }

    /// Runs a query and returns all its rows (columns fetched as characters).
    fn rows(&self, sql: &str, column_count: usize) -> Result<Vec<Vec<Option<String>>>, String> {
        let query = CString::new(sql).map_err(|e| e.to_string())?;
        // SAFETY: statement handle allocated and freed here, buffers sized here.
        unsafe {
            let mut st = 0;
            SQLAllocStmt(self.hdbc, &mut st);
            let rc = SQLExecDirect(st, query.as_ptr(), SQL_NTS);
            if rc != SQL_SUCCESS && rc != SQL_SUCCESS_WITH_INFO {
                let e = self.error_message(st, "SQLExecDirect");
                SQLFreeStmt(st, SQL_DROP);
                return Err(e);
            }
            let mut res = Vec::new();
            while SQLFetch(st) != SQL_NO_DATA_FOUND {
                let mut row = Vec::with_capacity(column_count);
                for col in 1..=column_count {
                    let mut buffer = [0 as c_char; 1024];
                    let mut ind = 0;
                    SQLGetData(st, col as c_short, SQL_C_CHAR, buffer.as_mut_ptr(), buffer.len() as c_int, &mut ind);
                    row.push(if ind == SQL_NULL_DATA { None } else { Some(c_text(&buffer)) });
                }
                res.push(row);
            }
            SQLFreeStmt(st, SQL_DROP);
            Ok(res)
        }
    }

    /// Runs a statement that returns no result set (INSERT, CREATE…).
    fn execute(&self, sql: &str) -> Result<(), String> {
        let query = CString::new(sql).map_err(|e| e.to_string())?;
        // SAFETY: statement handle allocated and freed here.
        unsafe {
            let mut st = 0;
            SQLAllocStmt(self.hdbc, &mut st);
            let rc = SQLExecDirect(st, query.as_ptr(), SQL_NTS);
            let r = if rc == SQL_SUCCESS || rc == SQL_SUCCESS_WITH_INFO { Ok(()) } else { Err(self.error_message(st, "SQLExecDirect")) };
            SQLFreeStmt(st, SQL_DROP);
            r
        }
    }
}

impl Drop for Db2 {
    fn drop(&mut self) {
        // SAFETY: handles allocated by connect().
        unsafe {
            SQLDisconnect(self.hdbc);
            SQLFreeConnect(self.hdbc);
            SQLFreeEnv(self.henv);
        }
    }
}

/// Null-terminated C string to String, trailing blanks removed.
fn c_text(buffer: &[c_char]) -> String {
    let bytes: Vec<u8> = buffer.iter().take_while(|&&c| c != 0).map(|&c| c as u8).collect();
    String::from_utf8_lossy(&bytes).trim_end().to_string()
}

/// SQL literal: single quotes doubled.
fn sql_literal(s: &str) -> String {
    format!("'{}'", s.replace('\'', "''"))
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    let schema = args.get(1).map(|s| s.trim().to_uppercase()).filter(|s| !s.is_empty()).unwrap_or("QSYS2".into());
    let limit: u32 = args.get(2).and_then(|s| s.trim().parse().ok()).unwrap_or(10);

    let result = (|| -> Result<usize, String> {
        let db = Db2::connect()?;
        let tables = db.rows(
            &format!(
                "SELECT TABLE_NAME, TABLE_TYPE, COALESCE(TABLE_TEXT, '') FROM QSYS2.SYSTABLES \
                 WHERE TABLE_SCHEMA = {} ORDER BY TABLE_NAME FETCH FIRST {limit} ROWS ONLY",
                sql_literal(&schema)
            ),
            3,
        )?;
        for t in &tables {
            let name = t[0].clone().unwrap_or_default();
            let table_type = t[1].clone().unwrap_or_default();
            let label = t[2].clone().unwrap_or_default();
            // the "Rust computation": name length in characters, and a readable type
            let kind = match table_type.as_str() {
                "T" | "P" => "table",
                "V" => "view",
                "L" => "logical",
                "A" => "alias",
                _ => "other",
            };
            println!("{name:<30} {kind:<8} {label}");
            // WITH NC: QTEMP is not journaled, no commitment control
            db.execute(&format!(
                "INSERT INTO QTEMP.RUSTTABLES (NOM, GENRE, TEXTE, LONGUEUR) VALUES ({}, {}, {}, {}) WITH NC",
                sql_literal(&name),
                sql_literal(kind),
                sql_literal(&label.chars().take(100).collect::<String>()),
                name.chars().count()
            ))?;
        }
        Ok(tables.len())
    })();

    match result {
        Ok(n) => {
            println!("rust-db2: {n} table(s) of {schema} written to QTEMP/RUSTTABLES");
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("rust-db2: {e}");
            ExitCode::from(1)
        }
    }
}
