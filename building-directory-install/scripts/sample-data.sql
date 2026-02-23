-- Sample companies
INSERT INTO companies (name, building, suite, phone, floor) VALUES
('Acme Corporation', 'A', '101', '555-0101', '1'),
('Tech Solutions Inc', 'A', '205', '555-0205', '2'),
('Global Consulting', 'B', '301', '555-0301', '3'),
('Design Studio', 'B', '102', '555-0102', '1');
-- Sample individuals
INSERT INTO individuals (first_name, last_name, company_id, building, suite, title, phone) VALUES
('John', 'Smith', 1, 'A', '101', 'CEO', '555-0111'),
('Jane', 'Doe', 1, 'A', '101', 'CFO', '555-0112'),
('Bob', 'Johnson', 2, 'A', '205', 'CTO', '555-0211'),
('Alice', 'Williams', 3, 'B', '301', 'Consultant', '555-0311');
-- Building info
INSERT INTO building_info (title, content, display_order) VALUES
('Building Information', '<h2>Office Hours</h2><p>Monday - Friday: 8:00 AM - 6:00 PM</p><h2>Emergency Contact</h2><p>Security: 555-0911</p><h2>Parking</h2><p>Visitor parking available in Lot C</p>', 0);
