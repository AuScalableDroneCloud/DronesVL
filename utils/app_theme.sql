List databases
# \l
Connect to database
# \c webodm_dev
List tables
# \dt
Describe table
# \d app_imageupload
SQL
# select * from app_theme;
--
-- PostgreSQL database dump
--

-- Dumped from database version 9.5.25
-- Dumped by pg_dump version 9.5.25

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Data for Name: app_theme; Type: TABLE DATA; Schema: public; Owner: postgres
--

INSERT INTO public.app_theme (id, name, "primary", secondary, tertiary, button_primary, button_default, button_danger, header_background, header_primary, border, highlight, dialog_warning, failed, success, css, html_before_header, html_after_header, html_after_body, html_footer) VALUES (1, 'Default1', '#2C3E50', '#FFFFFF', '#3498DB', '#2C3E50', '#95A5A6', '#E74C3C', '#3498DB', '#FFFFFF', '#E7E7E7', '#F7F7F7', '#F39C12', '#FFCBCB', '#CBFFCD', '', '', '', '', '');
INSERT INTO public.app_theme (id, name, "primary", secondary, tertiary, button_primary, button_default, button_danger, header_background, header_primary, border, highlight, dialog_warning, failed, success, css, html_before_header, html_after_header, html_after_body, html_footer) VALUES (3, 'Default', '#2c3e50', '#ffffff', '#3498db', '#2c3e50', '#95a5a6', '#e74c3c', '#3498db', '#ffffff', '#e7e7e7', '#f7f7f7', '#f39c12', '#ffcbcb', '#cbffcd', '', '', '', '', '');
INSERT INTO public.app_theme (id, name, "primary", secondary, tertiary, button_primary, button_default, button_danger, header_background, header_primary, border, highlight, dialog_warning, failed, success, css, html_before_header, html_after_header, html_after_body, html_footer) VALUES (2, 'ASDC_old', '#270F02', '#FFF9F0', '#69360E', '#B97F4D', '#8D9E3A', '#FF5442', '#913B26', '#FFFFFF', '#E7E7E7', '#F7F7F7', '#F39C12', '#FF968A', '#95DC9A', '', '', '', '', '');
INSERT INTO public.app_theme (id, name, "primary", secondary, tertiary, button_primary, button_default, button_danger, header_background, header_primary, border, highlight, dialog_warning, failed, success, css, html_before_header, html_after_header, html_after_body, html_footer) VALUES (4, 'ASDC', '#270F02', '#FFFBF5', '#881B00', '#5B8B51', '#9E9254', '#E74C3C', '#913B26', '#FFFFFF', '#EFE5D5', '#FFF7ED', '#F38609', '#FFA788', '#A0DC79', '', '', '', '', '');


--
-- Name: app_theme_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.app_theme_id_seq', 4, true);


--
-- PostgreSQL database dump complete
--

