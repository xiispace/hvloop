from libcpp.string cimport string
from libcpp cimport bool as bool_t
from libcpp.memory cimport shared_ptr


cdef extern from "http_client.h":
    ctypedef struct http_client_t

    http_client_t* http_client_new(const char* host, int port, int https)

cdef extern from "hstring.h":
    cdef cppclass StringCaseLess

cdef extern from "hmap.h" namespace "hv" nogil:
    ctypedef map[string, string] KeyValue

cdef extern from "http_content.h":
    ctypedef KeyValue    QueryParams


cdef extern from "httpdef.h":
    cdef enum http_status:
        HTTP_STATUS_CONTINUE = 100
        HTTP_STATUS_SWITCHING_PROTOCOLS = 101
        HTTP_STATUS_PROCESSING = 102
        HTTP_STATUS_OK = 200
        HTTP_STATUS_CREATED = 201
        HTTP_STATUS_ACCEPTED = 202
        HTTP_STATUS_NON_AUTHORITATIVE_INFORMATION = 203
        HTTP_STATUS_NO_CONTENT = 204
        HTTP_STATUS_RESET_CONTENT = 205
        HTTP_STATUS_PARTIAL_CONTENT = 206
        HTTP_STATUS_MULTI_STATUS = 207
        HTTP_STATUS_ALREADY_REPORTED = 208

    cdef enum http_method:
        HTTP_DELETE = 0
        HTTP_GET = 1
        HTTP_HEAD = 2
        HTTP_POST = 3
        HTTP_PUT = 4
        HTTP_CONNECT = 5
        HTTP_OPTIONS = 6


ctypedef map[string, string, StringCaseLess]  http_headers
ctypedef string http_body


cdef extern from "HttpMessage.h":
    ctypedef struct HNetAddr:
        string ip
        int port

    cdef cppclass HttpMessage:
        int type
        unsigned short http_major
        unsigned short http_minor

        http_headers headers
        http_body body
        void * content
        int content_length

    cdef cppclass HttpResponse:
        http_status status_code
        const char* status_message()

    cdef cppclass HttpRequest:
        http_method method
        string url
        bool_t https
        string host
        int port
        string path
        QueryParams query_params

        HNetAddr client_addr

cdef extern from "requests.h" namespace "requests":
    ctypedef shared_ptr[HttpRequest]  Request
    ctypedef shared_ptr[HttpResponse] Response

    Response request(http_method method, const char* url, const http_body& body, const http_headers& headers)


def crequest(int method, str url, ):
    py_byte_string = url.encode("utf-8")
    resp = request(HTTP_GET, <char *>py_byte_string)
    print("%d %s\r\n" % (resp.get().status_code, resp.get().status_message()))
